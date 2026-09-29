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
    /// Every app that has used audio since it started, playing or not.
    @Published private(set) var runningApps: [AudioApp] = []
    private var ownProcesses: [AudioObjectID] = []
    private var reRouters: [AudioObjectID] = []
    /// Apps playing now, and when each was last heard.
    private var playingApps: Set<String> = []
    private var lastPlayed: [String: Date] = [:]
    private var anyPlaying = false
    private var lastAnyPlaying = Date.distantPast
    /// Processes whose own output FreeAudio mutes because it renders them itself.
    private var takenOver: Set<AudioObjectID> = []
    let usage: UsageStats
    let hearing: HearingMonitor
    private let history: HistoryStore?
    private var lastRecord = Date()
    private var volumeDecibels: (uid: String, volume: Double, decibels: Double)?
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
    /// When FreeAudio itself last changed each level, keyed like `levels`: a change seen soon after is its own.
    private var ownWrites: [String: Date] = [:]
    /// Apps recording right now, by name, to tell in the log when a call starts or ends.
    private var recordingApps: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private var deviceRefreshScheduled = false
    /// The outputs apps are sent to whose level is followed.
    private var shownAppOutputs: Set<String> = []
    private var volumeRefreshScheduled = false
    private var requestingPermission = false
    /// FreeAudio asks by itself once per launch; after that only when the user asks.
    private var askedAutomatically = false
    private var lastPermissionCheck = Date.distantPast

    init(engineEnabled: Bool = true, showsWarnings: Bool = true) {
        self.engineEnabled = engineEnabled
        self.showsWarnings = showsWarnings
        state = PersistedState.load()
        // Previews and tests keep their numbers in memory and write no log.
        let support = engineEnabled ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first : nil
        if let support {
            Log.start(folder: support.appendingPathComponent("FreeAudio/logs"))
            Log.info("app", "啟動 FreeAudio \(BuildInfo.current.label)（\(ProcessInfo.processInfo.operatingSystemVersionString)）")
        }
        history = support.flatMap { HistoryStore(file: $0.appendingPathComponent("FreeAudio/history.sqlite")) }
        usage = UsageStats(store: history)
        hearing = HearingMonitor(store: history)
        permission = AudioCapturePermission.status
        lastPermissionCheck = Date()
        if engineEnabled {
            Log.info("app", "設定：鎖定裝置 \(state.locksDevices)、記住聲音 \(state.remembersSound)、麥克風跟著輸出 \(state.inputFollowsOutput)、"
                + "新裝置靜音 \(state.newDevicesSilent)；在 FreeAudio 靜音的麥克風 \(state.mutedMicrophones ?? [])、音量被壓到 0% 的 \(state.parkedMicrophones)")
        }
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
        hearing.onMonitoringChange = { [weak self] in self?.reconcileRoutes() }
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
        Log.info("device", "使用者選擇 \(describe(device, direction))")
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
        if let level = levels[levelKey(device, direction)] { return level }
        // One the panel doesn't follow: asked directly.
        let level = heardLevel(device, direction)
        return DeviceLevelState(volume: level.volume, muted: level.muted, adjustable: false)
    }

    func setVolume(_ volume: Double, for device: AudioDevice, _ direction: DeviceDirection) {
        let key = levelKey(device, direction)
        let volume = volume.clamped(to: 0...1)
        let shown = level(of: device, direction)
        // A slider can report its current value again, e.g. when it appears; that isn't a change.
        guard abs(volume - shown.volume) > 0.0005 else { return }
        // A drag is one line: its first step.
        if Date().timeIntervalSince(lastVolumeWrite[key] ?? .distantPast) > 1 {
            Log.info("level", "介面把 \(describe(device, direction)) 的音量從 \(percent(shown.volume)) 調成 \(percent(volume))")
        }
        levels[key]?.volume = volume
        lastVolumeWrite[key] = Date()
        if usesSoftwareLevel(device, direction) {
            updateDeviceSettings(for: device) { $0.volume = volume }
        } else {
            writeVolume(volume, device, direction, nil)
        }
        // Like the system controls, moving the slider un-mutes, at the level it was moved to.
        if volume > 0, shown.muted {
            softMuteVolumes[device.uid] = nil
            if direction == .input { state.parkedMicrophones[device.uid] = nil }
            setMuted(false, device, direction, "拖動音量滑桿")
        }
    }

    func toggleMute(_ device: AudioDevice, _ direction: DeviceDirection) {
        setMuted(!level(of: device, direction).muted, device, direction, "按下靜音按鈕")
    }

    /// Only for what the user does; `reason` says what, for the log.
    private func setMuted(_ muted: Bool, _ device: AudioDevice, _ direction: DeviceDirection, _ reason: String) {
        if direction == .input {
            setMicrophoneMuted(muted, device, reason)
        } else if device.canMute {
            writeMuted(muted, device, direction, reason)
        } else if usesSoftwareLevel(device, direction) {
            // No volume or mute control (e.g. HDMI): FreeAudio silences what it renders there.
            Log.info("level", "\(describe(device, direction)) \(muted ? "靜音" : "解除靜音")（由 FreeAudio 處理）：\(reason)")
            updateDeviceSettings(for: device) { $0.muted = muted }
        } else if muted {
            // Devices without a mute control are muted by parking the volume at zero.
            softMuteVolumes[device.uid] = AudioDevices.volume(device, direction) ?? 1
            writeVolume(0, device, direction, "\(reason)，沒有靜音控制，以 0% 代替")
        } else if let volume = softMuteVolumes.removeValue(forKey: device.uid) {
            writeVolume(volume, device, direction, "\(reason)，還原靜音前的音量")
        }
        refreshVolumes()
    }

    /// Every mute FreeAudio sets on a device goes through here: the log says why (nothing when `reason` is `nil`), and
    /// the change it causes isn't taken for someone else's.
    private func writeMuted(_ muted: Bool, _ device: AudioDevice, _ direction: DeviceDirection, _ reason: String?, level: Log.Level = .info) {
        ownWrites[levelKey(device, direction)] = Date()
        AudioDevices.setMuted(muted, device, direction)
        guard let reason else { return }
        let line = "\(describe(device, direction)) \(muted ? "靜音" : "解除靜音")：\(reason)"
        level == .warn ? Log.warn("level", line) : Log.info("level", line)
    }

    /// Like `writeMuted`, for a volume; the panel's slider passes no reason, and logs a drag once itself.
    private func writeVolume(_ volume: Double, _ device: AudioDevice, _ direction: DeviceDirection, _ reason: String?) {
        ownWrites[levelKey(device, direction)] = Date()
        AudioDevices.setVolume(volume, device, direction)
        if let reason { Log.info("level", "\(describe(device, direction)) 音量設為 \(percent(volume))：\(reason)") }
    }

    /// "MacBook Pro Speakers (output)", for the log.
    private func describe(_ device: AudioDevice, _ direction: DeviceDirection) -> String {
        "\(device.name)（\(direction == .output ? "輸出" : "輸入")）"
    }

    /// An output without a volume control gets its level from FreeAudio, applied to what FreeAudio renders on it.
    private func usesSoftwareLevel(_ device: AudioDevice, _ direction: DeviceDirection) -> Bool {
        direction == .output && !device.hasVolume
    }

    func refreshDevices() {
        let outputs = AudioDevices.list(.output)
        let inputs = AudioDevices.list(.input)
        let known = outputDevices + inputDevices
        if engineEnabled {
            logConnections(outputs, outputDevices, .output)
            logConnections(inputs, inputDevices, .input)
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
            if engineEnabled {
                let name = { (id: AudioDeviceID) in (known + outputs + inputs).first { $0.id == id }?.name ?? "無" }
                Log.info("device", "預設\(direction == .output ? "輸出" : "輸入")：\(name(previous)) → \(name(current))（\(ours ? "FreeAudio" : devicesListed ? "系統或其他 App" : "啟動時")）")
            }
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

    private func logConnections(_ now: [AudioDevice], _ before: [AudioDevice], _ direction: DeviceDirection) {
        // The first listing at launch isn't a connection.
        guard devicesListed else { return }
        for device in now where !before.contains(where: { $0.uid == device.uid }) { Log.info("device", "連接 \(describe(device, direction))") }
        for device in before where !now.contains(where: { $0.uid == device.uid }) { Log.info("device", "中斷 \(describe(device, direction))") }
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
            Log.info("lock", "鎖定的\(direction == .output ? "輸出" : "輸入") \(state.deviceNames[chosenUID] ?? chosenUID) 回來了")
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
                Log.warn("lock", "找不到鎖定的\(direction == .output ? "輸出" : "輸入") \(state.deviceNames[chosenUID] ?? chosenUID)，"
                    + "\(current.map { "\($0.name) 暫代並保持靜音" } ?? "沒有暫代的裝置")")
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
                Log.info("device", "麥克風跟著輸出換成 \(paired.name)")
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
        Log.info("device", "輸出改變時 macOS 換了麥克風，換回 \(previous.name)")
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
                if device.hasVolume { writeVolume(0, device, direction, "第一次連接的裝置預設 0%") }
                if device.canMute { writeMuted(true, device, direction, "第一次連接的裝置預設靜音") }
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
        let devices = direction == .output ? outputDevices : inputDevices
        guard let device = devices.first(where: { $0.id == id }) else { return }
        let current = devices.first { $0.id == (direction == .output ? outputDeviceID : inputDeviceID) }
        Log.info("lock", "預設\(direction == .output ? "輸出" : "輸入")被換成 \(current?.name ?? "無")，換回鎖定的 \(device.name)")
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
            writeMuted(true, device, direction, "鎖定的裝置不在，暫代的裝置保持靜音")
        } else if device.hasVolume {
            guard (AudioDevices.volume(device, direction) ?? 0) > 0 else { return }
            writeVolume(0, device, direction, "鎖定的裝置不在，暫代的裝置保持 0%")
        } else if direction == .output, silencers[device.uid] == nil, !ownProcesses.isEmpty {
            Log.info("level", "\(describe(device, direction)) 沒有音量與靜音控制，以 tap 讓它保持無聲")
            // No mute or volume control (e.g. HDMI): mute everything playing to it with a tap.
            let control = StageControl()
            control.update(StageSetup(gainLeft: 0, gainRight: 0))
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
            let reason = "不再暫代，還原它原本的狀態"
            if device.canMute {
                writeMuted(original.muted || held, device, direction, held ? "\(reason)（在 FreeAudio 靜音的麥克風維持靜音）" : reason)
            } else if device.hasVolume, !held {
                writeVolume(original.volume, device, direction, reason)
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
    private func setMicrophoneMuted(_ muted: Bool, _ device: AudioDevice, _ reason: String) {
        var microphones = Set(state.mutedMicrophones ?? [])
        if muted {
            guard device.canMute || device.hasVolume else { return }
            microphones.insert(device.uid)
            if device.canMute { writeMuted(true, device, .input, reason) } else { park(device, "\(reason)，沒有靜音控制，以 0% 代替") }
        } else {
            microphones.remove(device.uid)
            reMutes[device.uid] = nil
            if device.canMute { writeMuted(false, device, .input, reason) }
            if let volume = state.parkedMicrophones.removeValue(forKey: device.uid) {
                writeVolume(volume, device, .input, "\(reason)，還原靜音前的音量")
            }
        }
        state.mutedMicrophones = microphones.sorted()
        scheduleSave()
        installMuteGuards()
    }

    /// Holds a microphone's volume at zero, keeping the level to give back when it's unmuted in FreeAudio.
    private func park(_ device: AudioDevice, _ reason: String) {
        if state.parkedMicrophones[device.uid] == nil {
            state.parkedMicrophones[device.uid] = AudioDevices.volume(device, .input) ?? 1
            scheduleSave()
        }
        if (AudioDevices.volume(device, .input) ?? 0) > 0 { writeVolume(0, device, .input, reason) }
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
            if state.parkedMicrophones[device.uid] != nil {
                park(device, device.canMute ? "持續被解除靜音，保持 0%" : "麥克風沒有靜音控制，保持 0%")
            }
            guard device.canMute else { continue }
            let recent = reMutes[device.uid] ?? []
            let step = MicrophoneHold.step(muted: AudioDevices.isMuted(device, .input), recentMutes: recent, now: now)
            switch step {
            case .keep:
                continue
            case .retry(let delay):
                retryHold(after: delay)
            case .mute, .muteAndPark:
                // While its volume is held at zero, each fight isn't worth a line.
                let parked = state.parkedMicrophones[device.uid] != nil
                writeMuted(true, device, .input, parked ? nil : "在 FreeAudio 靜音，卻被系統或其他 App 解除靜音，再次靜音", level: .warn)
                reMutes[device.uid] = MicrophoneHold.recording(now, after: recent)
                if step == .muteAndPark, device.hasVolume {
                    park(device, "3 秒內被解除靜音 \(MicrophoneHold.persistentCount) 次，把音量設為 0%")
                }
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
                if device.hasVolume, !parked { writeVolume(level.volume, device, direction, "重新啟動後還原記住的音量") }
                if direction == .output, device.canMute { writeMuted(level.muted, device, direction, "重新啟動後還原記住的靜音狀態") }
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

    /// The devices whose level the panel shows: the default input and output, the extra outputs, and the outputs
    /// apps are sent to.
    private var watchedDevices: [(device: AudioDevice, direction: DeviceDirection)] {
        var devices: [(device: AudioDevice, direction: DeviceDirection)] = []
        if let defaultInput { devices.append((defaultInput, .input)) }
        if let defaultOutput { devices.append((defaultOutput, .output)) }
        return devices + (extraOutputs + appOutputs.map(\.device)).map { ($0, .output) }
    }

    /// Output devices running apps are sent to, other than the ones everything plays on, with the apps sent there.
    var appOutputs: [(device: AudioDevice, apps: [AudioApp])] {
        guard state.perAppEnabled else { return [] }
        let playing = Set([defaultOutput?.uid].compactMap { $0 } + extraOutputs.map(\.uid))
        var result: [(device: AudioDevice, apps: [AudioApp])] = []
        for app in runningApps {
            guard let uid = state.apps[app.id]?.outputUID, !playing.contains(uid),
                  let device = outputDevices.first(where: { $0.uid == uid }) else { continue }
            if let index = result.firstIndex(where: { $0.device == device }) {
                result[index].apps.append(app)
            } else {
                result.append((device, [app]))
            }
        }
        return result.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
    }

    /// The device an app is sent to, when it's muted or at zero, so the app can't be heard.
    func silentOutput(forApp id: String) -> AudioDevice? {
        guard let uid = state.apps[id]?.outputUID, let device = outputDevices.first(where: { $0.uid == uid }) else { return nil }
        let level = level(of: device, .output)
        return level.muted || level.volume <= 0.001 ? device : nil
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
            if engineEnabled { logOutsideChange(device, direction, volume: volume, muted: muted, now: now) }
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

    /// A level change on a shown device that neither FreeAudio nor its panel made: the keyboard, Control Center,
    /// another app, or macOS.
    private func logOutsideChange(_ device: AudioDevice, _ direction: DeviceDirection, volume: Double, muted: Bool, now: Date) {
        let key = levelKey(device, direction)
        guard let shown = levels[key],
              now.timeIntervalSince(ownWrites[key] ?? .distantPast) > 1,
              now.timeIntervalSince(lastVolumeWrite[key] ?? .distantPast) > 1 else { return }
        if shown.muted != muted {
            Log.info("level", "\(describe(device, direction)) 被系統或其他 App \(muted ? "靜音" : "解除靜音")")
        } else if abs(shown.volume - volume) >= 0.01 {
            Log.info("level", "\(describe(device, direction)) 的音量被系統或其他 App 從 \(percent(shown.volume)) 調成 \(percent(volume))")
        }
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
            // A hidden app stays listed in Settings under its name.
            if !state.hiddenApps.contains(id) { state.appNames[id] = nil }
        } else {
            state.apps[id] = settings
            if let name { state.appNames[id] = name }
        }
        configureAppControl(id)
        // The outputs apps are sent to show their level.
        outputsChanged()
        scheduleSave()
    }

    func isHidden(_ id: String) -> Bool { state.hiddenApps.contains(id) }

    /// Leaves an app out of the menu bar panel, or brings it back.
    func setHidden(_ hidden: Bool, app id: String, name: String) {
        state.hiddenApps.removeAll { $0 == id }
        if hidden {
            state.hiddenApps = (state.hiddenApps + [id]).sorted()
            state.appNames[id] = name
        } else if state.apps[id] == nil {
            state.appNames[id] = nil
        }
        updateVisibleApps(now: Date())
        scheduleSave()
    }

    /// Running apps, and apps with settings or hidden that aren't running, by name.
    var knownApps: [AudioApp] {
        let running = Set(runningApps.map(\.id))
        let others = Set(state.apps.keys).union(state.hiddenApps).subtracting(running).map { id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            return AudioApp(
                id: id, name: state.appNames[id] ?? url.map { FileManager.default.displayName(atPath: $0.path) } ?? id,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle),
                processes: [], isPlaying: false
            )
        }
        return (runningApps + others).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        if snapshot.apps != runningApps { runningApps = snapshot.apps }
        // A call starting or ending is when macOS moves and unmutes microphones.
        let recording = Set(snapshot.apps.filter { $0.processes.contains { snapshot.recording[$0] != nil } }.map(\.name))
        if engineEnabled, recording != recordingApps {
            for name in recording.subtracting(recordingApps).sorted() { Log.info("app", "\(name) 開始錄音") }
            for name in recordingApps.subtracting(recording).sorted() { Log.info("app", "\(name) 停止錄音") }
        }
        recordingApps = recording
        let running = Set(snapshot.apps.map(\.id))
        lastPlayed = lastPlayed.filter { running.contains($0.key) }
        usedDevices = usedDevices.filter { running.contains($0.key) }
        updateVisibleApps(now: now)
        // An app sent to a device of its own just started or quit: that device's level shows, or no longer does.
        if Set(appOutputs.map(\.device.uid)) != shownAppOutputs {
            shownAppOutputs = Set(appOutputs.map(\.device.uid))
            outputsChanged()
        } else {
            reconcileRoutes()
        }
    }

    private func updateVisibleApps(now: Date) {
        let visible = runningApps.filter {
            // Paused apps stay listed for a while, so their row doesn't vanish mid-adjustment.
            !state.hiddenApps.contains($0.id)
                && (state.apps[$0.id] != nil || $0.isPlaying || now.timeIntervalSince(lastPlayed[$0.id] ?? .distantPast) < 600)
        }
        if visible != apps { apps = visible }
    }

    /// When a route's source was last heard: now while it plays.
    private func lastActive(_ source: RouteKey.Source, now: Date) -> Date {
        switch source {
        case .app(let id): playingApps.contains(id) ? now : lastPlayed[id] ?? .distantPast
        case .system, .meter: anyPlaying ? now : lastAnyPlaying
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

    /// Outputs playing a copy of the default one while multi-output is on: checked, connected, and not the default.
    var extraOutputs: [AudioDevice] {
        guard state.globalMultiOutput else { return [] }
        return state.globalOutputUIDs.compactMap { uid in outputDevices.first { $0.uid == uid && $0.id != outputDeviceID } }
    }

    /// Checks or unchecks an output to play along with the main one, like an AirPlay speaker; see `MultiOutput.toggle`.
    /// Checking one turns multi-output on, and unchecking the last one that's connected turns it off.
    func toggleOutput(_ device: AudioDevice) {
        let connected = Set(outputDevices.map(\.uid))
        guard let main = defaultOutput,
              let next = MultiOutput.toggle(
                  device.uid, in: .init(main: main.uid, extras: state.globalMultiOutput ? state.globalOutputUIDs : []), connected: connected
              ) else { return }
        let on = next.extras.contains { $0 != next.main && connected.contains($0) }
        state.globalMultiOutput = on
        state.globalOutputUIDs = on ? next.extras : []
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
        Log.info("app", "重新掃描裝置與 App")
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
        Log.info("app", "從睡眠喚醒")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.rescan()
        }
    }

    func shutdown() {
        Log.info("app", "結束")
        saveTask?.cancel()
        state.save()
        usage.save()
        hearing.save()
        history?.close()
        timer?.invalidate()
        routes.values.forEach { $0.stop() }
        routes.removeAll()
        Log.flush()
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
        // Across sleep the gap isn't time anything was in use.
        let elapsed = min(now.timeIntervalSince(lastRecord), 2)
        lastRecord = now
        if engineEnabled {
            recordUsage(seconds: elapsed, at: now)
            recordHearing(elapsed: elapsed, at: now)
            usage.tick(at: now)
            hearing.tick(at: now)
            hearing.checkWeeklySummary(at: now)
        }
        // Also lets devices an app left drain, lingering routes go, and failed routes try again.
        reconcileRoutes()
    }

    // MARK: - Statistics and hearing

    /// Counts a second for every device an app plays to or records from, and for every app playing or recording,
    /// with its volume, whether it's muted, and the devices it uses. An app FreeAudio renders plays where FreeAudio
    /// does, so its own muted output doesn't count for a device.
    private func recordUsage(seconds: Double, at date: Date) {
        guard usage.settings.tracking else { return }
        let snapshot = monitor.snapshot
        let own = Set(snapshot.ownProcesses)
        let outputs = Set(snapshot.playing.filter { !takenOver.contains($0.key) }.values.joined())
        let inputs = Set(snapshot.recording.filter { !own.contains($0.key) }.values.joined())
        var uses = outputDevices.filter { outputs.contains($0.id) }.map { use($0, .output) }
        uses += inputDevices.filter { inputs.contains($0.id) }.map { use($0, .input) }
        for app in runningApps {
            let playsOn = Set(app.processes.flatMap { snapshot.playing[$0] ?? [] })
            if app.processes.contains(where: { snapshot.playing[$0] != nil }) {
                let settings = settings(for: app)
                // Heard where FreeAudio sends it, when it has a device of its own.
                let chosen = settings.outputUID.flatMap { uid in outputDevices.first { $0.uid == uid } }
                let devices = chosen.map { [$0.uid] + (settings.multiOutput ? settings.extraOutputUIDs : []) }
                    ?? outputDevices.filter { playsOn.contains($0.id) }.map(\.uid)
                uses.append(UsageStats.Use(
                    source: SourceKey(kind: .playingApp, key: app.id), name: app.name, volume: settings.volume,
                    muted: settings.muted || appOutputMissing(app.id), devices: devices.map { SourceKey(kind: .output, key: $0) }
                ))
            }
            // A recording app's volume is its microphone's.
            let recordsFrom = Set(app.processes.flatMap { snapshot.recording[$0] ?? [] })
            if !recordsFrom.isEmpty || app.processes.contains(where: { snapshot.recording[$0] != nil }) {
                let microphones = inputDevices.filter { recordsFrom.contains($0.id) }
                let microphone = microphones.first.map { level(of: $0, .input) }
                uses.append(UsageStats.Use(
                    source: SourceKey(kind: .recordingApp, key: app.id), name: app.name, volume: microphone?.volume ?? 0,
                    muted: microphone?.muted ?? false, devices: microphones.map { SourceKey(kind: .input, key: $0.uid) }
                ))
            }
        }
        usage.record(uses, seconds: seconds, at: date)
    }

    private func use(_ device: AudioDevice, _ direction: DeviceDirection) -> UsageStats.Use {
        let level = heardLevel(device, direction)
        return UsageStats.Use(source: SourceKey(kind: direction == .output ? .output : .input, key: device.uid), name: device.name,
                              volume: level.volume, muted: level.muted)
    }

    /// A device's level, also for one the panel doesn't show.
    private func heardLevel(_ device: AudioDevice, _ direction: DeviceDirection) -> (volume: Double, muted: Bool) {
        if let level = levels[levelKey(device, direction)] { return (level.volume, level.muted) }
        if usesSoftwareLevel(device, direction) {
            let settings = deviceSettings(for: device.uid)
            return (settings.volume, settings.muted)
        }
        return (AudioDevices.volume(device, direction) ?? 1, AudioDevices.isMuted(device, direction))
    }

    /// The meter only runs while something plays; a second it didn't measure was silent.
    private func recordHearing(elapsed: Double, at date: Date) {
        guard hearing.settings.monitoring, let device = defaultOutput else { return }
        let measurement = routes.first { $0.key.isMeter }?.value.takeMeasurement()
        let level = level(of: device, .output)
        hearing.record(
            meanSquare: measurement?.meanSquare, seconds: measurement?.seconds ?? elapsed, device: device, volume: level.volume,
            volumeDecibels: decibels(level.volume, device), muted: level.muted, at: date
        )
    }

    /// The device's output level in dB at `volume`, from its own scale; FreeAudio's software level is already in
    /// what the meter hears. Worked out again only when the volume changes.
    private func decibels(_ volume: Double, _ device: AudioDevice) -> Double {
        guard !usesSoftwareLevel(device, .output) else { return 0 }
        if let cached = volumeDecibels, cached.uid == device.uid, cached.volume == volume { return cached.decibels }
        let decibels = AudioDevices.decibels(volume, device) ?? Exposure.approximateDecibels(volume: volume)
        volumeDecibels = (device.uid, volume, decibels)
        return decibels
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
        takenOver = Set(desired.values.filter { spec in
            if case .app = spec.key.source { return spec.mute == .muted }
            return false
        }.flatMap(\.processes))
        if let failure, failure != lastError {
            Log.error("route", failure)
            lastError = failure
        } else if failure == nil, retryAfter.isEmpty, lastError != nil { lastError = nil }
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
            own: ownProcesses + reRouters,
            meter: hearing.settings.monitoring
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
        var stage = (state.apps[id] ?? AppAudioSettings()).stage
        if appOutputMissing(id) { (stage.gainLeft, stage.gainRight) = (0, 0) }
        control.update(stage)
    }

    private func configureDeviceControl(_ uid: String) {
        deviceControls[uid]?.update(deviceSettings(for: uid).stage)
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
