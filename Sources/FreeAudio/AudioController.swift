import AppKit
import Combine
import CoreAudio

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var inputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    /// Volume and mute of the default input and output, and of the extra outputs while multi-output is on,
    /// keyed like `PersistedState.deviceLevels`.
    @Published private(set) var levels: [String: DeviceLevelState] = [:]

    /// Running apps that played recently or have saved settings.
    @Published private(set) var apps: [AudioApp] = []
    /// Other audio tools that are processing audio right now; running both leads to doubled sound.
    @Published private(set) var conflictingApps: [String] = []
    @Published private(set) var permission: AudioCapturePermission.Status
    @Published private(set) var lastError: String?
    @Published private(set) var state: PersistedState
    /// Chosen devices that aren't connected; their directions are silenced until they're back.
    @Published private(set) var missingDevices: [DeviceDirection: MissingDevice] = [:]
    /// Devices something else switched to (e.g. macOS when headphones connect) that FreeAudio switched away from.
    @Published private(set) var blockedDevices: [DeviceDirection: AudioDevice] = [:]

    private let engineEnabled: Bool
    private let showsWarnings: Bool
    /// Directions whose chosen device is put back after launch; that isn't reported as a blocked switch.
    private var restoreOnLaunch: Set<DeviceDirection> = []
    private var lastSwitchBack: [DeviceDirection: Date] = [:]
    /// The last default-device change per direction, to spot the microphone moving along with the output.
    private var lastChange: [DeviceDirection: DefaultChange] = [:]
    /// Default devices FreeAudio itself is switching to; their change notifications aren't someone else's.
    private var switchingTo: [DeviceDirection: AudioDeviceID] = [:]
    /// macOS moves the microphone within this long of the output changing.
    private static let sideEffectWindow: TimeInterval = 3

    private struct DefaultChange {
        var at: Date
        var from: AudioDeviceID
        var byFreeAudio: Bool
        /// Already acted on (or seen at launch, which isn't a change to act on).
        var handled: Bool
    }
    private var switchBackRetry: Task<Void, Never>?
    private var lastSilenced: [String: Date] = [:]
    private var devicesListed = false
    /// Output devices without mute or volume control, silenced with a tap instead.
    private var silencers: [String: AudioRoute] = [:]
    private var warningTask: Task<Void, Never>?
    private var warningPanel: WarningPanel?
    private lazy var monitor = ProcessMonitor { [weak self] in self?.processesChanged() }
    private var runningApps: [AudioApp] = []
    private var ownProcesses: [AudioObjectID] = []
    private var reRouters: [AudioObjectID] = []
    /// Apps playing now, and when each was last heard.
    private var playingApps: Set<String> = []
    private var lastPlayed: [String: Date] = [:]
    private var anyPlaying = false
    private var lastAnyPlaying = Date.distantPast
    /// Output devices each running app plays to, and when it was last seen playing there.
    private var usedDevices: [String: [String: Date]] = [:]
    private var routes: [RouteKey: AudioRoute] = [:]
    private var lingering: [RouteKey: Date] = [:]
    private var retryAfter: [RouteKey: Date] = [:]
    private var appControls: [String: StageControl] = [:]
    private var deviceControls: [String: StageControl] = [:]
    private var systemListeners: [PropertyListener] = []
    private var volumeListeners: [PropertyListener] = []
    private var observedVolumeDevices: [String] = []
    private var sampleRateListeners: [String: PropertyListener] = [:]
    private var sampleRates: [String: Float64] = [:]
    private var softMuteVolumes: [String: Double] = [:]
    /// What's still to be put back after launch; cleared once applied or after `restoreWindow`.
    private var pendingDefaults: [DeviceDirection: String] = [:]
    private var pendingLevels: Set<String> = []
    private let launchDate = Date()
    /// Listeners on every held microphone (see `MicrophoneHold`), and when FreeAudio last muted each one again.
    private var muteGuards: [AudioDeviceID: [PropertyListener]] = [:]
    private var reMutes: [String: [Date]] = [:]
    private var holdRetry: Task<Void, Never>?
    /// Bluetooth devices can take a while to connect after login.
    private static let restoreWindow: TimeInterval = 120
    /// When the panel last set each level, keyed like `levels`.
    private var lastVolumeWrite: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private var deviceRefreshScheduled = false
    private var volumeRefreshScheduled = false
    private var requestingPermission = false
    /// FreeAudio asks by itself once per launch; after that only when the user asks.
    private var askedAutomatically = false
    private var lastPermissionCheck = Date.distantPast

    init(engineEnabled: Bool = true, showsWarnings: Bool = true) {
        self.engineEnabled = engineEnabled
        self.showsWarnings = showsWarnings
        state = PersistedState.load()
        permission = AudioCapturePermission.status
        lastPermissionCheck = Date()
        // Previews and tests (engine off) must not touch the user's devices.
        if engineEnabled {
            if state.locksDevices, !state.lockSeeded {
                // Start the lock from the devices in use now; `choose` records them on the first refresh.
                state.preferredDevices.removeAll()
                state.lockSeeded = true
            } else if state.locksDevices {
                restoreOnLaunch = [.output, .input]
            } else if state.remembersSound {
                for direction in [DeviceDirection.output, .input] {
                    pendingDefaults[direction] = state.preferredDevices[direction.key]
                }
            }
            if state.remembersSound { pendingLevels = Set(state.deviceLevels.keys) }
        }
        refreshDevices()
        installSystemListeners()
        monitor.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes keep it running while a warning is on screen.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
        // Aggregate devices don't always survive sleep.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanAfterWake() }
        })
    }

    var defaultOutput: AudioDevice? { outputDevices.first { $0.id == outputDeviceID } }
    var defaultInput: AudioDevice? { inputDevices.first { $0.id == inputDeviceID } }
    enum MicrophoneState { case on, muted, unavailable }

    /// For the menu bar icon: no usable microphone (none at all, or the chosen one is missing), muted, or on.
    var microphoneState: MicrophoneState {
        if inputDevices.isEmpty || missingDevices[.input] != nil { return .unavailable }
        return defaultInput.map { level(of: $0, .input).muted } == true ? .muted : .on
    }

    func isDisabled(_ direction: DeviceDirection) -> Bool { missingDevices[direction] != nil }

    #if DEBUG
    /// Lets layout snapshots and tests show a missing device without touching real ones.
    func previewMissing(_ direction: DeviceDirection, name: String, warn: Bool = false) {
        missingDevices[direction] = MissingDevice(uid: "preview", name: name)
        if warn { scheduleWarning() }
    }

    func previewReconnected(_ direction: DeviceDirection) {
        missingDevices[direction] = nil
        dismissWarning()
    }

    func previewBlocked(_ direction: DeviceDirection, _ device: AudioDevice) {
        blockedDevices[direction] = device
    }
    #endif

    func deviceName(uid: String) -> String {
        outputDevices.first { $0.uid == uid }?.name ?? state.deviceNames[uid] ?? uid
    }

    // MARK: - Devices

    /// Picking a device in FreeAudio makes it the chosen one.
    func select(_ device: AudioDevice, _ direction: DeviceDirection) {
        choose(device, direction)
        setDefault(device.id, direction)
        refreshDevices()
    }

    private func setDefault(_ id: AudioDeviceID, _ direction: DeviceDirection) {
        guard AudioDevices.defaultDevice(direction) != id else { return }
        switchingTo[direction] = id
        AudioDevices.setDefault(id, direction)
    }

    /// Stops waiting for a missing device and uses the one macOS picked instead.
    func useCurrentDevice(_ direction: DeviceDirection) {
        let devices = direction == .output ? outputDevices : inputDevices
        guard let current = devices.first(where: { $0.id == AudioDevices.defaultDevice(direction) }) else { return }
        select(current, direction)
    }

    func level(of device: AudioDevice, _ direction: DeviceDirection) -> DeviceLevelState {
        levels[levelKey(device, direction)] ?? DeviceLevelState(volume: 0, muted: false, adjustable: false)
    }

    func setVolume(_ volume: Double, for device: AudioDevice, _ direction: DeviceDirection) {
        let key = levelKey(device, direction)
        let volume = volume.clamped(to: 0...1)
        let shown = level(of: device, direction)
        // A slider can report its current value again, e.g. when it appears; that isn't a change.
        guard abs(volume - shown.volume) > 0.0005 else { return }
        levels[key]?.volume = volume
        lastVolumeWrite[key] = Date()
        if usesSoftwareLevel(device, direction) {
            updateDeviceSettings(for: device) { $0.volume = volume }
        } else {
            AudioDevices.setVolume(volume, device, direction)
        }
        // Like the system controls, moving the slider un-mutes, at the level it was moved to.
        if volume > 0, shown.muted {
            softMuteVolumes[device.uid] = nil
            if direction == .input { state.parkedMicrophones[device.uid] = nil }
            setMuted(false, device, direction)
        }
    }

    func toggleMute(_ device: AudioDevice, _ direction: DeviceDirection) {
        setMuted(!level(of: device, direction).muted, device, direction)
    }

    private func setMuted(_ muted: Bool, _ device: AudioDevice, _ direction: DeviceDirection) {
        if direction == .input {
            setMicrophoneMuted(muted, device)
        } else if device.canMute {
            AudioDevices.setMuted(muted, device, direction)
        } else if usesSoftwareLevel(device, direction) {
            // No volume or mute control (e.g. HDMI): FreeAudio silences what it renders there.
            updateDeviceSettings(for: device) { $0.muted = muted }
        } else if muted {
            // Devices without a mute control are muted by parking the volume at zero.
            softMuteVolumes[device.uid] = AudioDevices.volume(device, direction) ?? 1
            AudioDevices.setVolume(0, device, direction)
        } else if let volume = softMuteVolumes.removeValue(forKey: device.uid) {
            AudioDevices.setVolume(volume, device, direction)
        }
        refreshVolumes()
    }

    /// An output without a volume control gets its level from FreeAudio, applied to what FreeAudio renders on it.
    private func usesSoftwareLevel(_ device: AudioDevice, _ direction: DeviceDirection) -> Bool {
        direction == .output && !device.hasVolume
    }

    func refreshDevices() {
        let outputs = AudioDevices.list(.output)
        let inputs = AudioDevices.list(.input)
        if engineEnabled {
            takeOverMicrophoneMutes(inputs)
            quietNewDevices(outputs: outputs, inputs: inputs)
        }
        if outputs != outputDevices { outputDevices = outputs }
        if inputs != inputDevices { inputDevices = inputs }
        restoreRememberedSound()
        for direction in [DeviceDirection.output, .input] {
            let current = AudioDevices.defaultDevice(direction)
            let previous = direction == .output ? outputDeviceID : inputDeviceID
            guard current != previous else { continue }
            if direction == .output { outputDeviceID = current } else { inputDeviceID = current }
            let ours = switchingTo[direction] == current
            switchingTo[direction] = nil
            lastChange[direction] = DefaultChange(at: Date(), from: previous, byFreeAudio: ours, handled: !devicesListed)
            if !state.locksDevices { rememberDefault(direction, previous: previous) }
        }
        devicesListed = true
        let keptMicrophone = engineEnabled && followOrKeepMicrophone()
        if engineEnabled, state.locksDevices {
            enforceDeviceLock(.output)
            // The microphone was just put back; the lock has nothing to report about it.
            if !keptMicrophone { enforceDeviceLock(.input) }
        }
        // With nothing remembered yet, the devices in use now are the ones to come back to.
        for (direction, device) in [(DeviceDirection.output, defaultOutput), (.input, defaultInput)] {
            guard state.remembersSound || state.locksDevices, pendingDefaults[direction] == nil,
                  state.preferredDevices[direction.key] == nil, let device else { continue }
            choose(device, direction)
        }
        for direction in [DeviceDirection.output, .input] where missingDevices[direction] == nil {
            releaseSilenced(direction)
        }
        // A blocked device that's been disconnected needs no notice any more.
        for (direction, device) in blockedDevices where !(direction == .output ? outputs : inputs).contains(where: { $0.uid == device.uid }) {
            blockedDevices[direction] = nil
        }
        for id in state.apps.keys { configureAppControl(id) }
        installMuteGuards()
        holdMicrophoneMutes()
        refreshVolumes()
        installVolumeListeners()
        reconcileRoutes()
    }

    // MARK: - Device lock

    func setLocksDevices(_ on: Bool) {
        state.locksDevices = on
        restoreOnLaunch.removeAll()
        if on {
            for (direction, device) in [(DeviceDirection.output, defaultOutput), (.input, defaultInput)] {
                if let device, state.preferredDevices[direction.key] == nil { choose(device, direction) }
            }
        } else {
            for direction in [DeviceDirection.output, .input] {
                missingDevices[direction] = nil
                releaseSilenced(direction)
            }
            dismissWarning()
            if !state.remembersSound { state.preferredDevices.removeAll() }
        }
        scheduleSave()
        refreshDevices()
    }

    /// Keeps the default device on the chosen one; never replaces a missing one.
    private func enforceDeviceLock(_ direction: DeviceDirection) {
        guard let chosenUID = state.preferredDevices[direction.key] else { return }
        let devices = direction == .output ? outputDevices : inputDevices
        let currentID = direction == .output ? outputDeviceID : inputDeviceID
        let current = devices.first { $0.id == currentID }
        let decision = DeviceLock.decide(chosenUID: chosenUID, devices: devices, currentID: currentID)
        let wasMissing = missingDevices[direction] != nil
        if decision != .missing, wasMissing {
            missingDevices[direction] = nil
            dismissWarning()
        }
        switch decision {
        case .keep:
            restoreOnLaunch.remove(direction)
        case .switchBack(let id):
            // Going back after launch or a reconnect is expected; a switch made elsewhere is reported.
            if !restoreOnLaunch.contains(direction), !wasMissing, let current { blockedDevices[direction] = current }
            restoreOnLaunch.remove(direction)
            switchBack(direction, to: id)
        case .missing:
            if missingDevices[direction] == nil {
                missingDevices[direction] = MissingDevice(uid: chosenUID, name: state.deviceNames[chosenUID] ?? L("guard.unknown_device"))
                scheduleWarning()
            }
            // Whatever macOS switched to in its place stays silent.
            if let current { silence(current, direction) }
        }
    }

    /// macOS moves the microphone to a headset when the headset becomes the output. By default the microphone
    /// stays where it was; with "switch microphone with output" on, the output's own microphone is chosen.
    /// Returns whether the microphone was just put back.
    private func followOrKeepMicrophone() -> Bool {
        let now = Date()
        guard let output = lastChange[.output], now.timeIntervalSince(output.at) < Self.sideEffectWindow else { return false }
        if state.inputFollowsOutput {
            // Once per output change, whoever made it.
            guard !output.handled else { return false }
            lastChange[.output]?.handled = true
            if let device = defaultOutput, let paired = AudioDevices.pairedInput(for: device, among: inputDevices) {
                choose(paired, .input)
                setDefault(paired.id, .input)
            }
            return false
        }
        guard let input = lastChange[.input], !input.handled, !input.byFreeAudio,
              abs(input.at.timeIntervalSince(output.at)) < Self.sideEffectWindow,
              let previous = inputDevices.first(where: { $0.id == input.from }) else { return false }
        lastChange[.input]?.handled = true
        blockedDevices[.input] = nil
        if state.locksDevices || state.remembersSound { choose(previous, .input) }
        setDefault(previous.id, .input)
        return true
    }

    /// A speaker or microphone FreeAudio has never seen starts at 0% and muted, so it can't play or listen
    /// by surprise. Everything connected the first time FreeAudio runs is taken as already known.
    private func quietNewDevices(outputs: [AudioDevice], inputs: [AudioDevice]) {
        let seeding = state.knownDevices == nil
        var known = Set(state.knownDevices ?? [])
        if seeding {
            // Devices this or an earlier version already dealt with aren't new either.
            known.formUnion(state.deviceLevels.keys)
            known.formUnion(state.silencedLevels.keys)
            for (direction, uid) in state.preferredDevices { known.insert("\(direction):\(uid)") }
        }
        let before = known.count
        for (direction, devices) in [(DeviceDirection.output, outputs), (.input, inputs)] {
            for device in devices {
                guard known.insert(levelKey(device, direction)).inserted, !seeding, state.newDevicesSilent else { continue }
                if device.hasVolume { AudioDevices.setVolume(0, device, direction) }
                if device.canMute { AudioDevices.setMuted(true, device, direction) }
                // A new microphone stays muted until it's unmuted in FreeAudio.
                if direction == .input, device.canMute || device.hasVolume {
                    state.mutedMicrophones = ((state.mutedMicrophones ?? []) + [device.uid]).sorted()
                    if !device.canMute { state.parkedMicrophones[device.uid] = 0 }
                }
            }
        }
        guard seeding || known.count != before else { return }
        state.knownDevices = known.sorted()
        scheduleSave()
    }

    func setInputFollowsOutput(_ on: Bool) {
        state.inputFollowsOutput = on
        scheduleSave()
    }

    func setNewDevicesSilent(_ on: Bool) {
        state.newDevicesSilent = on
        scheduleSave()
    }

    private func switchBack(_ direction: DeviceDirection, to id: AudioDeviceID) {
        let wait = DeviceLock.minimumSwitchInterval - Date().timeIntervalSince(lastSwitchBack[direction] ?? .distantPast)
        guard wait <= 0 else {
            // Something keeps switching away: try again shortly instead of spinning.
            switchBackRetry?.cancel()
            switchBackRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refreshDevices()
            }
            return
        }
        lastSwitchBack[direction] = Date()
        setDefault(id, direction)
    }

    func dismissBlocked(_ direction: DeviceDirection) {
        blockedDevices[direction] = nil
    }

    private func choose(_ device: AudioDevice, _ direction: DeviceDirection) {
        restoreOnLaunch.remove(direction)
        pendingDefaults[direction] = nil
        blockedDevices[direction] = nil
        state.deviceNames[device.uid] = device.name
        if state.remembersSound || state.locksDevices { state.preferredDevices[direction.key] = device.uid }
        if missingDevices[direction] != nil {
            missingDevices[direction] = nil
            releaseSilenced(direction)
            dismissWarning()
        }
        scheduleSave()
    }

    /// Mutes a stand-in device, remembering how it was. Also re-mutes it when something else turns it back on.
    private func silence(_ device: AudioDevice, _ direction: DeviceDirection) {
        let key = levelKey(device, direction)
        if state.silencedLevels[key] == nil {
            state.silencedLevels[key] = DeviceLevel(
                volume: AudioDevices.volume(device, direction) ?? 1,
                muted: AudioDevices.isMuted(device, direction)
            )
            scheduleSave()
        }
        // Don't get into a tug of war with whatever keeps unmuting it.
        guard Date().timeIntervalSince(lastSilenced[key] ?? .distantPast) > 0.25 else { return }
        if device.canMute {
            guard !AudioDevices.isMuted(device, direction) else { return }
            AudioDevices.setMuted(true, device, direction)
        } else if device.hasVolume {
            guard (AudioDevices.volume(device, direction) ?? 0) > 0 else { return }
            AudioDevices.setVolume(0, device, direction)
        } else if direction == .output, silencers[device.uid] == nil, !ownProcesses.isEmpty {
            // No mute or volume control (e.g. HDMI): mute everything playing to it with a tap.
            let control = StageControl()
            control.update(gainLeft: 0, gainRight: 0, eq: EQSettings())
            let key = RouteKey(source: .system, deviceUID: device.uid, tapDeviceUID: device.uid)
            let spec = RouteSpec(key: key, processes: ownProcesses.sorted(), mute: .muted)
            silencers[device.uid] = try? AudioRoute(spec: spec, appControl: nil, deviceControl: control)
        }
        lastSilenced[key] = Date()
    }

    /// Puts back every device silenced for a direction, once its chosen device is back or replaced by the user.
    private func releaseSilenced(_ direction: DeviceDirection) {
        let prefix = direction.key + ":"
        let devices = direction == .output ? outputDevices : inputDevices
        for (key, original) in state.silencedLevels where key.hasPrefix(prefix) {
            let uid = String(key.dropFirst(prefix.count))
            // A device that's gone is put back when it returns.
            guard let device = devices.first(where: { $0.uid == uid }) else { continue }
            // A microphone muted in FreeAudio stays muted.
            let held = direction == .input && isHeld(device)
            if device.canMute {
                AudioDevices.setMuted(original.muted || held, device, direction)
            } else if device.hasVolume, !held {
                AudioDevices.setVolume(original.volume, device, direction)
            }
            state.silencedLevels[key] = nil
            scheduleSave()
        }
        if direction == .output {
            silencers.values.forEach { $0.stop() }
            silencers.removeAll()
        }
    }

    // MARK: - Microphone mute

    private func isHeld(_ device: AudioDevice) -> Bool { state.mutedMicrophones?.contains(device.uid) == true }

    /// The first time this version runs, the microphones muted now, or saved as muted, count as muted in FreeAudio.
    private func takeOverMicrophoneMutes(_ inputs: [AudioDevice]) {
        guard state.mutedMicrophones == nil else { return }
        let saved = state.deviceLevels.compactMap { key, level in
            level.muted && key.hasPrefix("input:") ? String(key.dropFirst("input:".count)) : nil
        }
        let mutedNow = inputs.filter { $0.canMute && AudioDevices.isMuted($0, .input) }.map(\.uid)
        state.mutedMicrophones = Set(saved + mutedNow).sorted()
        scheduleSave()
    }

    /// Unmuting here is the only way a microphone muted in FreeAudio opens again.
    private func setMicrophoneMuted(_ muted: Bool, _ device: AudioDevice) {
        var microphones = Set(state.mutedMicrophones ?? [])
        if muted {
            guard device.canMute || device.hasVolume else { return }
            microphones.insert(device.uid)
            if device.canMute { AudioDevices.setMuted(true, device, .input) } else { park(device) }
        } else {
            microphones.remove(device.uid)
            reMutes[device.uid] = nil
            if device.canMute { AudioDevices.setMuted(false, device, .input) }
            if let volume = state.parkedMicrophones.removeValue(forKey: device.uid) {
                AudioDevices.setVolume(volume, device, .input)
            }
        }
        state.mutedMicrophones = microphones.sorted()
        scheduleSave()
        installMuteGuards()
    }

    /// Holds a microphone's volume at zero, keeping the level to give back when it's unmuted in FreeAudio.
    private func park(_ device: AudioDevice) {
        if state.parkedMicrophones[device.uid] == nil {
            state.parkedMicrophones[device.uid] = AudioDevices.volume(device, .input) ?? 1
            scheduleSave()
        }
        if (AudioDevices.volume(device, .input) ?? 0) > 0 { AudioDevices.setVolume(0, device, .input) }
    }

    /// Watches every held microphone, not only the default one: an app can record from any of them.
    private func installMuteGuards() {
        guard engineEnabled else { return }
        let ids = Set(inputDevices.filter(isHeld).map(\.id))
        guard ids != Set(muteGuards.keys) else { return }
        muteGuards = muteGuards.filter { ids.contains($0.key) }
        for id in ids where muteGuards[id] == nil {
            muteGuards[id] = AudioDevices.observedAddresses(.input).compactMap {
                PropertyListener(id, $0) { [weak self] in self?.holdMicrophoneMutes() }
            }
        }
    }

    /// Mutes again every held microphone something else unmuted; see `MicrophoneHold`.
    private func holdMicrophoneMutes() {
        guard engineEnabled else { return }
        let now = Date()
        for device in inputDevices where isHeld(device) {
            if state.parkedMicrophones[device.uid] != nil { park(device) }
            guard device.canMute else { continue }
            let recent = reMutes[device.uid] ?? []
            let step = MicrophoneHold.step(muted: AudioDevices.isMuted(device, .input), recentMutes: recent, now: now)
            switch step {
            case .keep:
                continue
            case .retry(let delay):
                retryHold(after: delay)
            case .mute, .muteAndPark:
                AudioDevices.setMuted(true, device, .input)
                reMutes[device.uid] = MicrophoneHold.recording(now, after: recent)
                if step == .muteAndPark, device.hasVolume { park(device) }
            }
        }
    }

    private func retryHold(after delay: TimeInterval) {
        guard holdRetry == nil else { return }
        holdRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.holdRetry = nil
            self?.holdMicrophoneMutes()
        }
    }

    // MARK: - Missing device warning

    private func scheduleWarning() {
        guard showsWarnings else { return }
        // Give a device that blinked out (Bluetooth, waking from sleep) a moment, and more right after login.
        let delay: TimeInterval = Date().timeIntervalSince(launchDate) < 30 ? 15 : 3
        warningTask?.cancel()
        warningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.presentWarning()
        }
    }

    private func presentWarning() {
        let pending = missingDevices.filter { !$0.value.warned }
        guard !pending.isEmpty else { return }
        for direction in pending.keys { missingDevices[direction]?.warned = true }
        warningPanel?.close()

        let output = pending[.output], input = pending[.input]
        let title: String
        switch (output, input) {
        case let (output?, input?) where output.name != input.name:
            title = LF("guard.missing_title_two", output.name, input.name)
        default:
            title = LF("guard.missing_title", (output ?? input)?.name ?? "")
        }
        let text = L(output != nil && input != nil ? "guard.both_disabled" : output != nil ? "guard.output_disabled" : "guard.input_disabled")
        var buttons: [(title: String, action: () -> Void)] = [(L("guard.ok"), {})]
        let directions = Array(pending.keys)
        let useCurrent: () -> Void = { [weak self] in
            for direction in directions where self?.missingDevices[direction] != nil { self?.useCurrentDevice(direction) }
        }
        if pending.count == 1, let stand = output != nil ? defaultOutput : defaultInput {
            buttons.append((LF("guard.use_current", stand.name), useCurrent))
        } else if (output == nil || defaultOutput != nil) && (input == nil || defaultInput != nil) {
            buttons.append((L("guard.use_current_devices"), useCurrent))
        }
        let panel = WarningPanel(title: title, text: text, buttons: buttons) { [weak self] in
            self?.warningPanel = nil
        }
        warningPanel = panel
        panel.show()
    }

    /// Closes the warning once nothing is missing any more.
    private func dismissWarning() {
        guard missingDevices.isEmpty else { return }
        warningTask?.cancel()
        warningPanel?.close()
        warningPanel = nil
    }

    // MARK: - Remembered sound

    func setRemembersSound(_ on: Bool) {
        state.remembersSound = on
        pendingDefaults.removeAll()
        pendingLevels.removeAll()
        if on {
            for (direction, device) in [(DeviceDirection.output, defaultOutput), (.input, defaultInput)] {
                if let device, state.preferredDevices[direction.key] == nil { choose(device, direction) }
            }
            refreshVolumes()
        } else {
            // The device lock still needs to know the chosen devices.
            if !state.locksDevices { state.preferredDevices.removeAll() }
            state.deviceLevels.removeAll()
        }
        scheduleSave()
    }

    /// After a restart, puts back the devices, volumes and mutes FreeAudio saw last.
    private func restoreRememberedSound() {
        guard !pendingDefaults.isEmpty || !pendingLevels.isEmpty else { return }
        guard Date().timeIntervalSince(launchDate) < Self.restoreWindow else {
            pendingDefaults.removeAll()
            pendingLevels.removeAll()
            return
        }
        for direction in [DeviceDirection.output, .input] {
            let devices = direction == .output ? outputDevices : inputDevices
            if let uid = pendingDefaults[direction], let device = devices.first(where: { $0.uid == uid }) {
                pendingDefaults[direction] = nil
                setDefault(device.id, direction)
            }
            for device in devices {
                let key = levelKey(device, direction)
                guard pendingLevels.remove(key) != nil, let level = state.deviceLevels[key] else { continue }
                // Microphone mutes are held rather than restored: FreeAudio never unmutes one by itself.
                let parked = direction == .input && state.parkedMicrophones[device.uid] != nil
                if device.hasVolume, !parked { AudioDevices.setVolume(level.volume, device, direction) }
                if direction == .output, device.canMute { AudioDevices.setMuted(level.muted, device, direction) }
            }
        }
    }

    /// Records the user's device choice. A switch forced by the previous device going away isn't a choice.
    private func rememberDefault(_ direction: DeviceDirection, previous: AudioDeviceID) {
        let devices = direction == .output ? outputDevices : inputDevices
        let current = direction == .output ? outputDeviceID : inputDeviceID
        guard state.remembersSound,
              devices.contains(where: { $0.id == previous }),
              let device = devices.first(where: { $0.id == current }) else { return }
        // Choosing a device yourself during the restore window beats restoring the old one.
        pendingDefaults[direction] = nil
        guard state.preferredDevices[direction.key] != device.uid else { return }
        state.preferredDevices[direction.key] = device.uid
        scheduleSave()
    }

    /// Remembers a default device's volume and mute, once anything saved for it has been put back.
    private func rememberLevel(_ device: AudioDevice?, _ direction: DeviceDirection, volume: Double, muted: Bool) {
        guard state.remembersSound, let device else { return }
        let key = levelKey(device, direction)
        guard !pendingLevels.contains(key) else { return }
        // A microphone is muted when FreeAudio holds it; what macOS briefly does to it isn't a setting.
        let level = direction == .input
            ? DeviceLevel(volume: state.parkedMicrophones[device.uid] ?? volume, muted: isHeld(device))
            : DeviceLevel(volume: volume, muted: muted)
        guard state.deviceLevels[key] != level else { return }
        state.deviceLevels[key] = level
        scheduleSave()
    }

    private func levelKey(_ device: AudioDevice, _ direction: DeviceDirection) -> String { "\(direction.key):\(device.uid)" }

    /// The devices whose level the panel shows: the default input and output, and the extra outputs.
    private var watchedDevices: [(device: AudioDevice, direction: DeviceDirection)] {
        var devices: [(device: AudioDevice, direction: DeviceDirection)] = []
        if let defaultInput { devices.append((defaultInput, .input)) }
        if let defaultOutput { devices.append((defaultOutput, .output)) }
        return devices + extraOutputs.map { ($0, .output) }
    }

    private func refreshVolumes() {
        for direction in [DeviceDirection.output, .input] {
            // Whatever macOS picked in place of a missing device stays silent.
            if engineEnabled, state.locksDevices, missingDevices[direction] != nil,
               let device = direction == .output ? defaultOutput : defaultInput {
                silence(device, direction)
            }
        }
        let now = Date()
        var next: [String: DeviceLevelState] = [:]
        for (device, direction) in watchedDevices {
            let key = levelKey(device, direction)
            let software = usesSoftwareLevel(device, direction)
            let volume = software ? deviceSettings(for: device.uid).volume : AudioDevices.volume(device, direction) ?? 1
            let muted = muteState(device, direction)
            // A stand-in's silence is FreeAudio's doing, not a level to remember.
            if state.silencedLevels[key] == nil, device.hasVolume || device.canMute {
                rememberLevel(device, direction, volume: volume, muted: muted)
            }
            var level = DeviceLevelState(volume: volume, muted: muted, adjustable: device.hasVolume || software)
            // Ignore read-backs while the user is dragging, so the slider doesn't jitter.
            if now.timeIntervalSince(lastVolumeWrite[key] ?? .distantPast) < 0.4, let shown = levels[key] {
                level.volume = shown.volume
            }
            next[key] = level
        }
        if next != levels { levels = next }
    }

    private func muteState(_ device: AudioDevice, _ direction: DeviceDirection) -> Bool {
        if direction == .input {
            if device.canMute, AudioDevices.isMuted(device, .input) { return true }
            // Held at zero volume: it has no mute control, or something kept unmuting it.
            return isHeld(device) && state.parkedMicrophones[device.uid] != nil && (AudioDevices.volume(device, .input) ?? 1) == 0
        }
        if device.canMute { return AudioDevices.isMuted(device, direction) }
        if usesSoftwareLevel(device, direction) { return deviceSettings(for: device.uid).muted }
        if softMuteVolumes[device.uid] != nil, (AudioDevices.volume(device, direction) ?? 0) > 0 {
            softMuteVolumes[device.uid] = nil
        }
        return softMuteVolumes[device.uid] != nil
    }

    private func installSystemListeners() {
        let deviceSelectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        systemListeners = deviceSelectors.compactMap { selector in
            PropertyListener(CA.system, CA.address(selector)) { [weak self] in self?.scheduleDeviceRefresh() }
        }
    }

    private func installVolumeListeners() {
        let watched = watchedDevices
        let keys = watched.map { "\(levelKey($0.device, $0.direction))#\($0.device.id)" }
        guard keys != observedVolumeDevices else { return }
        observedVolumeDevices = keys
        volumeListeners = watched.flatMap { device, direction -> [PropertyListener] in
            AudioDevices.observedAddresses(direction).compactMap {
                PropertyListener(device.id, $0) { [weak self] in
                    // A held microphone is muted again first, so the panel never shows it open.
                    if direction == .input { self?.holdMicrophoneMutes() }
                    self?.scheduleVolumeRefresh()
                }
            }
        }
    }

    private func scheduleDeviceRefresh() {
        guard !deviceRefreshScheduled else { return }
        deviceRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.deviceRefreshScheduled = false
            self?.refreshDevices()
        }
    }

    /// One volume change notifies several properties at once (the virtual main volume and each channel's); they're
    /// read back once.
    private func scheduleVolumeRefresh() {
        guard !volumeRefreshScheduled else { return }
        volumeRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.volumeRefreshScheduled = false
            self?.refreshVolumes()
        }
    }

    // MARK: - Apps

    func settings(for app: AudioApp) -> AppAudioSettings { state.apps[app.id] ?? AppAudioSettings() }

    func updateSettings(for app: AudioApp, _ change: (inout AppAudioSettings) -> Void) {
        var settings = settings(for: app)
        change(&settings)
        setSettings(settings, forApp: app.id, name: app.name)
    }

    func resetSettings(forApp id: String) {
        setSettings(AppAudioSettings(), forApp: id, name: nil)
    }

    func resetAllAppSettings() {
        for id in state.apps.keys { resetSettings(forApp: id) }
    }

    private func setSettings(_ settings: AppAudioSettings, forApp id: String, name: String?) {
        guard settings != (state.apps[id] ?? AppAudioSettings()) else { return }
        if settings.isDefault {
            state.apps[id] = nil
            state.appNames[id] = nil
        } else {
            state.apps[id] = settings
            if let name { state.appNames[id] = name }
        }
        configureAppControl(id)
        reconcileRoutes()
        scheduleSave()
    }

    func setPerAppEnabled(_ enabled: Bool) {
        state.perAppEnabled = enabled
        reconcileRoutes()
        scheduleSave()
    }

    private func processesChanged() {
        let snapshot = monitor.snapshot
        let now = Date()
        ownProcesses = snapshot.ownProcesses
        reRouters = snapshot.reRouters
        if snapshot.conflictingApps != conflictingApps { conflictingApps = snapshot.conflictingApps }
        // Playing now, or just stopped.
        if snapshot.anyPlaying || anyPlaying { lastAnyPlaying = now }
        anyPlaying = snapshot.anyPlaying
        for app in snapshot.apps where app.isPlaying || playingApps.contains(app.id) { lastPlayed[app.id] = now }
        playingApps = Set(snapshot.apps.filter(\.isPlaying).map(\.id))
        runningApps = snapshot.apps
        let running = Set(snapshot.apps.map(\.id))
        lastPlayed = lastPlayed.filter { running.contains($0.key) }
        usedDevices = usedDevices.filter { running.contains($0.key) }
        updateVisibleApps(now: now)
        reconcileRoutes()
    }

    private func updateVisibleApps(now: Date) {
        let visible = runningApps.filter {
            // Paused apps stay listed for a while, so their row doesn't vanish mid-adjustment.
            state.apps[$0.id] != nil || $0.isPlaying || now.timeIntervalSince(lastPlayed[$0.id] ?? .distantPast) < 600
        }
        if visible != apps { apps = visible }
    }

    /// When a route's source was last heard: now while it plays.
    private func lastActive(_ source: RouteKey.Source, now: Date) -> Date {
        switch source {
        case .app(let id): playingApps.contains(id) ? now : lastPlayed[id] ?? .distantPast
        case .system: anyPlaying ? now : lastAnyPlaying
        }
    }

    /// Output devices the app plays to; see `RoutePlan.devicesInUse`.
    private func devicesInUse(_ app: AudioApp) -> [String] {
        let playing = monitor.snapshot.playing
        let current = app.processes.flatMap { process in
            (playing[process] ?? []).compactMap { device in outputDevices.first { $0.id == device }?.uid }
        }
        let seen = RoutePlan.devicesInUse(seen: usedDevices[app.id] ?? [:], current: current, now: Date())
        usedDevices[app.id] = seen
        return seen.keys.sorted()
    }

    // MARK: - Output processing and multi-output

    func deviceSettings(for uid: String) -> DeviceAudioSettings { state.devices[uid] ?? DeviceAudioSettings() }

    func updateDeviceSettings(for device: AudioDevice, _ change: (inout DeviceAudioSettings) -> Void) {
        var settings = deviceSettings(for: device.uid)
        change(&settings)
        setDeviceSettings(settings, uid: device.uid, name: device.name)
    }

    func resetDeviceSettings(uid: String) {
        setDeviceSettings(DeviceAudioSettings(), uid: uid, name: nil)
    }

    private func setDeviceSettings(_ settings: DeviceAudioSettings, uid: String, name: String?) {
        guard settings != deviceSettings(for: uid) else { return }
        state.devices[uid] = settings.isDefault ? nil : settings
        if let name { state.deviceNames[uid] = name }
        configureDeviceControl(uid)
        // A device without a volume control shows the level kept here.
        refreshVolumes()
        reconcileRoutes()
        scheduleSave()
    }

    func setGlobalMultiOutput(_ enabled: Bool) {
        state.globalMultiOutput = enabled
        scheduleSave()
        outputsChanged()
    }

    /// Outputs playing a copy of the default one while multi-output is on: checked, connected, and not the default.
    var extraOutputs: [AudioDevice] {
        guard state.globalMultiOutput else { return [] }
        return state.globalOutputUIDs.compactMap { uid in outputDevices.first { $0.uid == uid && $0.id != outputDeviceID } }
    }

    /// Checks or unchecks an output while multi-output is on; see `MultiOutput.toggle`.
    func toggleOutput(_ device: AudioDevice) {
        guard let main = defaultOutput,
              let next = MultiOutput.toggle(
                  device.uid, in: .init(main: main.uid, extras: state.globalOutputUIDs), connected: Set(outputDevices.map(\.uid))
              ) else { return }
        state.globalOutputUIDs = next.extras
        state.deviceNames[device.uid] = device.name
        scheduleSave()
        if next.main != main.uid, let newMain = outputDevices.first(where: { $0.uid == next.main }) {
            select(newMain, .output)
        } else {
            outputsChanged()
        }
    }

    private func outputsChanged() {
        refreshVolumes()
        installVolumeListeners()
        reconcileRoutes()
    }

    // MARK: - Permission

    func openPrivacySettings() { AudioCapturePermission.openSystemSettings() }

    private func refreshPermission() {
        lastPermissionCheck = Date()
        let status = AudioCapturePermission.status
        guard status != permission else { return }
        permission = status
        reconcileRoutes()
    }

    /// Shows the macOS prompt for System Audio Recording. Without an answer FreeAudio
    /// isn't listed in Privacy & Security, so the user can't turn it on there either.
    func requestPermission() {
        guard !requestingPermission else { return }
        requestingPermission = true
        // Bring the menu bar app forward so the prompt isn't left behind other windows.
        NSApp.activate()
        let asked = AudioCapturePermission.request { [weak self] granted in
            Task { @MainActor [weak self] in self?.finishPermissionRequest(granted: granted) }
        }
        if !asked {
            // Without the prompt API, macOS asks by itself when a route starts.
            requestingPermission = false
            permission = .unknown
            reconcileRoutes()
        }
    }

    private func finishPermissionRequest(granted: Bool) {
        requestingPermission = false
        lastPermissionCheck = Date()
        permission = granted ? .authorized : AudioCapturePermission.status
        reconcileRoutes()
    }

    // MARK: - Routing

    /// Re-reads devices, apps and permission, and rebuilds every route.
    func rescan() {
        routes.values.forEach { $0.stop() }
        routes.removeAll()
        lingering.removeAll()
        retryAfter.removeAll()
        lastError = nil
        permission = AudioCapturePermission.status
        lastPermissionCheck = Date()
        refreshDevices()
        monitor.reload()
    }

    private func rescanAfterWake() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.rescan()
        }
    }

    func shutdown() {
        saveTask?.cancel()
        state.save()
        timer?.invalidate()
        routes.values.forEach { $0.stop() }
        routes.removeAll()
    }

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastPermissionCheck) > (permission == .authorized ? 30 : 2) { refreshPermission() }
        // In case a change came without a notification.
        holdMicrophoneMutes()
        updateVisibleApps(now: now)
        for (key, route) in routes {
            let activity = route.poll()
            guard activity.rendering else { continue }
            let lastActive = lastActive(key.source, now: now)
            if now.timeIntervalSince(lastActive) > 15 {
                // Let idle routes stop so output devices can sleep; they restart with the next audio.
                route.rearm()
            } else if now.timeIntervalSince(lastActive) < 2, let silence = activity.silentFor, silence > 8 {
                // A tap can stop delivering audio until it's rebuilt, which would leave its app muted.
                // A fresh route only re-arms this check once it hears sound, so real silence costs one rebuild.
                route.stop()
                routes[key] = nil
            }
        }
        // Also lets devices an app left drain, lingering routes go, and failed routes try again.
        reconcileRoutes()
    }

    private func reconcileRoutes() {
        guard engineEnabled else { return }
        var desired = desiredRoutes()
        if !desired.isEmpty {
            switch permission {
            case .authorized, .unknown:
                break
            case .notDetermined:
                if !askedAutomatically {
                    askedAutomatically = true
                    requestPermission()
                }
                desired = [:]
            case .denied:
                desired = [:]
            }
        }

        let now = Date()
        var failure: String?
        for (key, spec) in desired {
            lingering[key] = nil
            if let route = routes[key] {
                if route.spec == spec { continue }
                if route.spec.canUpdateInPlace(to: spec), route.updateProcesses(spec.processes) { continue }
                route.stop()
                routes[key] = nil
            }
            if let retry = retryAfter[key], retry > now { continue }
            do {
                routes[key] = try AudioRoute(
                    spec: spec,
                    appControl: appControl(for: key),
                    deviceControl: deviceControl(for: key.deviceUID)
                )
                retryAfter[key] = nil
            } catch {
                retryAfter[key] = now.addingTimeInterval(5)
                failure = error.localizedDescription
            }
        }

        // Old routes go only after the new ones are up, so audio is never left unprocessed in between.
        let appsWithRoutes = Set(desired.keys.compactMap { key -> String? in
            if case .app(let id) = key.source { return id }
            return nil
        })
        for (key, route) in routes where desired[key] == nil {
            if keepsLingering(key, appsWithRoutes: appsWithRoutes, now: now) { continue }
            route.stop()
            routes[key] = nil
            lingering[key] = nil
        }
        retryAfter = retryAfter.filter { desired[$0.key] != nil }
        if let failure, failure != lastError { lastError = failure } else if failure == nil, retryAfter.isEmpty, lastError != nil { lastError = nil }
        updateSampleRateListeners()
    }

    /// A route whose app just went back to default settings stays briefly,
    /// so dragging a slider across 100% doesn't tear it down and rebuild it.
    private func keepsLingering(_ key: RouteKey, appsWithRoutes: Set<String>, now: Date) -> Bool {
        guard case .app(let id) = key.source, !appsWithRoutes.contains(id),
              permission != .denied, runningApps.contains(where: { $0.id == id }) else { return false }
        let deadline = lingering[key] ?? now.addingTimeInterval(1.5)
        lingering[key] = deadline
        return deadline > now
    }

    private func desiredRoutes() -> [RouteKey: RouteSpec] {
        // Without knowing our own process, a system tap could capture FreeAudio's output.
        guard let defaultUID = defaultOutput?.uid, !ownProcesses.isEmpty else { return [:] }
        let apps = state.perAppEnabled ? runningApps.filter { state.apps[$0.id] != nil } : []
        return RoutePlan.routes(
            defaultUID: defaultUID,
            outputs: Set(outputDevices.map(\.uid)),
            silenced: Set(silencers.keys),
            state: state,
            apps: apps.map { app in
                RoutePlan.App(
                    id: app.id, processes: app.processes, playsOn: devicesInUse(app), outputMissing: appOutputMissing(app.id)
                )
            },
            own: ownProcesses + reRouters
        )
    }

    private func appControl(for key: RouteKey) -> StageControl? {
        guard case .app(let id) = key.source else { return nil }
        if let control = appControls[id] { return control }
        let control = StageControl()
        appControls[id] = control
        configureAppControl(id)
        return control
    }

    private func deviceControl(for uid: String) -> StageControl {
        if let control = deviceControls[uid] { return control }
        let control = StageControl()
        deviceControls[uid] = control
        configureDeviceControl(uid)
        return control
    }

    /// An app whose chosen output device isn't connected is silenced rather than moved to another device.
    func appOutputMissing(_ id: String) -> Bool {
        guard state.locksDevices, let uid = state.apps[id]?.outputUID else { return false }
        return !outputDevices.contains { $0.uid == uid }
    }

    private func configureAppControl(_ id: String) {
        guard let control = appControls[id] else { return }
        let settings = state.apps[id] ?? AppAudioSettings()
        let gain = settings.muted || appOutputMissing(id) ? 0 : settings.volume
        let balance = settings.balance.balanceGains
        control.update(gainLeft: gain * balance.left, gainRight: gain * balance.right, eq: settings.eq)
    }

    private func configureDeviceControl(_ uid: String) {
        guard let control = deviceControls[uid] else { return }
        let settings = deviceSettings(for: uid)
        let balance = settings.balance.balanceGains
        control.update(gainLeft: settings.gain * balance.left, gainRight: settings.gain * balance.right, eq: settings.eq)
    }

    /// Routes are built for the device's sample rate, so they're rebuilt when it changes.
    private func updateSampleRateListeners() {
        let uids = Set(routes.keys.map(\.deviceUID))
        for uid in sampleRateListeners.keys where !uids.contains(uid) {
            sampleRateListeners[uid] = nil
            sampleRates[uid] = nil
        }
        for uid in uids where sampleRateListeners[uid] == nil {
            guard let device = CA.device(uid: uid) else { continue }
            let address = CA.address(kAudioDevicePropertyNominalSampleRate)
            sampleRates[uid] = CA.value(device, address, fallback: Float64(0))
            sampleRateListeners[uid] = PropertyListener(device, address) { [weak self] in
                guard let self else { return }
                let rate = CA.value(device, address, fallback: Float64(0))
                guard rate != sampleRates[uid] else { return }
                sampleRates[uid] = rate
                for (key, route) in routes where key.deviceUID == uid {
                    route.stop()
                    routes[key] = nil
                }
                reconcileRoutes()
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.state.save()
        }
    }
}
