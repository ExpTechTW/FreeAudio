import AppKit
import CoreAudio
import UniformTypeIdentifiers

/// An application and all of the Core Audio process objects that belong to it
/// (helpers such as browser or Electron renderers are grouped under their app).
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    var processes: [AudioObjectID]
    var isPlaying: Bool
}

/// Keeps track of the processes doing audio, from Core Audio's notifications rather than by asking: every question
/// is a round trip into coreaudiod, and asking about each process every second kept it measurably busy.
@MainActor
final class ProcessMonitor {
    struct Snapshot {
        var apps: [AudioApp] = []
        /// Process objects that belong to FreeAudio itself.
        var ownProcesses: [AudioObjectID] = []
        /// Processes that play back other processes' audio. FreeAudio never taps them,
        /// since each app would keep capturing the other's output.
        var reRouters: [AudioObjectID] = []
        /// Names of audio tools (like FreeAudio) that are processing audio right now.
        var conflictingApps: [String] = []
        /// Whether any other process is currently producing output.
        var anyPlaying = false
        /// The devices each process plays to and records from right now; FreeAudio's own included.
        var playing: [AudioObjectID: [AudioObjectID]] = [:]
        var recording: [AudioObjectID: [AudioObjectID]] = [:]
    }

    private struct Identity {
        let key: String
        let name: String
        let icon: NSImage
        let isAccessory: Bool
    }

    private struct Entry {
        let pid: pid_t
        let identity: Identity?
        var listener: PropertyListener?
        var playing = false
        var recording = false
        var outputs: [AudioObjectID] = []
        var inputs: [AudioObjectID] = []
    }

    private(set) var snapshot = Snapshot()
    private var entries: [AudioObjectID: Entry] = [:]
    private var reRouters: Set<AudioObjectID> = []
    private var listListener: PropertyListener?
    private var publishScheduled = false
    private let ownPID = getpid()
    private let ownBundleID = Bundle.main.bundleIdentifier
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        listListener = PropertyListener(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.updateList()
        }
        updateList()
        publish()
    }

    /// Reads everything again, in case a notification went missing (e.g. across sleep).
    func reload() {
        entries.removeAll()
        reRouters.removeAll()
        updateList()
        publish()
    }

    private func updateList() {
        let objects = CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), as: AudioObjectID.self)
        let live = Set(objects)
        entries = entries.filter { live.contains($0.key) }
        reRouters.formIntersection(live)
        for object in objects where entries[object] == nil {
            let pid = CA.value(object, CA.address(kAudioProcessPropertyPID), fallback: pid_t(-1))
            var entry = Entry(pid: pid, identity: pid == ownPID ? nil : Self.resolve(pid: pid))
            // Starting or stopping output or input, or moving to another device, changes these.
            let any = CA.address(kAudioObjectPropertySelectorWildcard, scope: kAudioObjectPropertyScopeWildcard, element: kAudioObjectPropertyElementWildcard)
            entry.listener = PropertyListener(object, any) { [weak self] in self?.update(object) }
            entries[object] = entry
            read(object)
        }
        schedulePublish()
    }

    private func update(_ object: AudioObjectID) {
        read(object)
        schedulePublish()
    }

    private func read(_ object: AudioObjectID) {
        guard var entry = entries[object] else { return }
        entry.playing = CA.value(object, CA.address(kAudioProcessPropertyIsRunningOutput), fallback: UInt32(0)) != 0
        entry.recording = CA.value(object, CA.address(kAudioProcessPropertyIsRunningInput), fallback: UInt32(0)) != 0
        entry.outputs = entry.playing ? CA.array(object, CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput), as: AudioObjectID.self) : []
        entry.inputs = entry.recording ? CA.array(object, CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput), as: AudioObjectID.self) : []
        // Tap-based audio tools read their input from private aggregate devices, which don't show up in the public
        // device list; one doing that while it plays is taken for one from then on.
        if entry.pid != ownPID, entry.playing, entry.recording, !reRouters.contains(object) {
            let publicDevices = Set(CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), as: AudioObjectID.self))
            if entry.inputs.allSatisfy({ !publicDevices.contains($0) }) { reRouters.insert(object) }
        }
        entries[object] = entry
    }

    /// One snapshot for a burst of notifications.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            self?.publishScheduled = false
            self?.publish()
        }
    }

    private func publish() {
        var snapshot = Snapshot()
        var grouped: [String: AudioApp] = [:]
        var routerApps: [String: String] = [:]
        for (object, entry) in entries.sorted(by: { $0.key < $1.key }) {
            if entry.playing { snapshot.playing[object] = entry.outputs }
            if entry.recording { snapshot.recording[object] = entry.inputs }
            if entry.pid == ownPID {
                snapshot.ownProcesses.append(object)
                continue
            }
            if entry.playing { snapshot.anyPlaying = true }
            if reRouters.contains(object) {
                snapshot.reRouters.append(object)
                // A menu bar app doing this is another audio tool, not a call or a DAW.
                if let identity = entry.identity, identity.isAccessory { routerApps[identity.key] = identity.name }
            }
            guard let identity = entry.identity, identity.key != ownBundleID else { continue }
            grouped[identity.key, default: AudioApp(id: identity.key, name: identity.name, icon: identity.icon, processes: [], isPlaying: false)]
                .processes.append(object)
            if entry.playing { grouped[identity.key]?.isPlaying = true }
        }
        if snapshot.ownProcesses.isEmpty, let own = CA.processObject(pid: ownPID) {
            snapshot.ownProcesses.append(own)
        }
        for key in routerApps.keys {
            snapshot.reRouters += grouped.removeValue(forKey: key)?.processes ?? []
        }
        snapshot.reRouters = Array(Set(snapshot.reRouters)).sorted()
        snapshot.conflictingApps = routerApps.values.sorted()
        snapshot.apps = grouped.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.snapshot = snapshot
        onChange()
    }

    private static func resolve(pid: pid_t) -> Identity? {
        guard pid > 0 else { return nil }
        for candidate in [responsiblePID(for: pid), pid] where candidate > 0 {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy != .prohibited,
               let key = app.bundleIdentifier {
                return Identity(key: key, name: app.localizedName ?? key, icon: app.icon ?? genericIcon,
                                isAccessory: app.activationPolicy == .accessory)
            }
        }
        guard let bundleURL = enclosingApp(of: pid),
              let bundle = Bundle(url: bundleURL),
              let key = bundle.bundleIdentifier else { return nil }
        let name = (FileManager.default.displayName(atPath: bundleURL.path) as NSString).deletingPathExtension
        let isAccessory = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
        return Identity(key: key, name: name, icon: NSWorkspace.shared.icon(forFile: bundleURL.path), isAccessory: isAccessory)
    }

    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The outermost `.app` bundle containing the process executable.
    private static func enclosingApp(of pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.upperBound].dropLast()))
    }

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        responsibilityFunction?(pid) ?? pid
    }
}

private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

/// Maps helper processes (WebKit, Chromium, Electron…) to the app that launched them.
private let responsibilityFunction: ResponsibilityFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
}()
