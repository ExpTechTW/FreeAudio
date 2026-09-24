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
    }

    private struct Identity {
        let key: String
        let name: String
        let icon: NSImage
        let isAccessory: Bool
    }

    private var identities: [AudioObjectID: Identity?] = [:]
    private var reRouters: Set<AudioObjectID> = []
    private let ownPID = getpid()
    private let ownBundleID = Bundle.main.bundleIdentifier

    func scan() -> Snapshot {
        let objects = CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), as: AudioObjectID.self)
        let live = Set(objects)
        identities = identities.filter { live.contains($0.key) }
        reRouters.formIntersection(live)
        let publicDevices = Set(CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), as: AudioObjectID.self))

        var snapshot = Snapshot()
        var grouped: [String: AudioApp] = [:]
        var routerApps: [String: String] = [:]
        for object in objects {
            let pid = CA.value(object, CA.address(kAudioProcessPropertyPID), fallback: pid_t(-1))
            if pid == ownPID {
                snapshot.ownProcesses.append(object)
                continue
            }
            let playing = CA.value(object, CA.address(kAudioProcessPropertyIsRunningOutput), fallback: UInt32(0)) != 0
            if playing { snapshot.anyPlaying = true }
            if playing, !reRouters.contains(object), Self.looksLikeReRouter(object, publicDevices: publicDevices) {
                reRouters.insert(object)
            }
            let identity = identity(for: object, pid: pid)
            if reRouters.contains(object) {
                snapshot.reRouters.append(object)
                // A menu bar app doing this is another audio tool, not a call or a DAW.
                if let identity, identity.isAccessory { routerApps[identity.key] = identity.name }
            }
            guard let identity, identity.key != ownBundleID else { continue }
            grouped[identity.key, default: AudioApp(id: identity.key, name: identity.name, icon: identity.icon, processes: [], isPlaying: false)]
                .processes.append(object)
            if playing { grouped[identity.key]?.isPlaying = true }
        }
        if snapshot.ownProcesses.isEmpty, let own = CA.processObject(pid: ownPID) {
            snapshot.ownProcesses.append(own)
        }
        for key in routerApps.keys {
            snapshot.reRouters += grouped.removeValue(forKey: key)?.processes ?? []
        }
        snapshot.reRouters = Array(Set(snapshot.reRouters))
        snapshot.conflictingApps = routerApps.values.sorted()
        snapshot.apps = grouped.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return snapshot
    }

    /// Tap-based audio tools read their input from private aggregate devices,
    /// which don't show up in the public device list.
    private static func looksLikeReRouter(_ object: AudioObjectID, publicDevices: Set<AudioObjectID>) -> Bool {
        guard CA.value(object, CA.address(kAudioProcessPropertyIsRunningInput), fallback: UInt32(0)) != 0 else { return false }
        let inputs = CA.array(object, CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput), as: AudioObjectID.self)
        return inputs.allSatisfy { !publicDevices.contains($0) }
    }

    private func identity(for object: AudioObjectID, pid: pid_t) -> Identity? {
        if let cached = identities[object] { return cached }
        let identity = Self.resolve(pid: pid)
        identities[object] = .some(identity)
        return identity
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
