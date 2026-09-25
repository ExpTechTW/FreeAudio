import CoreAudio

/// Which routes the settings call for. Pure, so what each setting does to the audio can be checked without devices.
enum RoutePlan {
    struct App {
        let id: String
        let processes: [AudioObjectID]
        /// Output devices it plays to now.
        let playsOn: [String]
        /// Its chosen output device isn't connected.
        let outputMissing: Bool
    }

    /// `own` are processes never tapped: FreeAudio itself, and other tools that play back what they capture.
    static func routes(
        defaultUID: String, outputs: Set<String>, silenced: Set<String>, state: PersistedState, apps: [App], own: [AudioObjectID]
    ) -> [RouteKey: RouteSpec] {
        // Only while the switch is on: turning it off takes every copy away at once.
        let globalExtras = state.globalMultiOutput ? state.globalOutputUIDs.filter { $0 != defaultUID && outputs.contains($0) } : []

        var specs: [RouteKey: RouteSpec] = [:]
        func add(_ source: RouteKey.Source, to deviceUID: String, tapping processes: [AudioObjectID], on tapDevice: String?, mute: CATapMuteBehavior) {
            let key = RouteKey(source: source, deviceUID: deviceUID, tapDeviceUID: tapDevice)
            // A device silenced as a stand-in for a missing one gets nothing from FreeAudio either.
            guard specs[key] == nil, !silenced.contains(deviceUID) else { return }
            specs[key] = RouteSpec(key: key, processes: processes.sorted(), mute: mute)
        }

        // Apps whose audio FreeAudio renders itself, and apps kept out of the system-wide mirror.
        var takenOver: [AudioObjectID] = []
        var unmirrored: [AudioObjectID] = []
        if state.perAppEnabled {
            for app in apps {
                guard let settings = state.apps[app.id] else { continue }
                let source = RouteKey.Source.app(app.id)
                let chosen = settings.outputUID.flatMap { outputs.contains($0) ? $0 : nil }
                let extras = settings.multiOutput ? settings.extraOutputUIDs.filter(outputs.contains) : []
                // The app's own output stays muted for as long as FreeAudio renders it, so mute and
                // volume are only gain changes: instant, and nothing leaks when playback starts.
                if let chosen {
                    // Moves all of the app's audio to the chosen device.
                    add(source, to: chosen, tapping: app.processes, on: nil, mute: .muted)
                    for uid in extras where uid != chosen { add(source, to: uid, tapping: app.processes, on: nil, mute: .unmuted) }
                    takenOver += app.processes
                } else if app.outputMissing {
                    // Its device isn't connected: keep the app silent instead of playing it elsewhere.
                    add(source, to: defaultUID, tapping: app.processes, on: nil, mute: .muted)
                    takenOver += app.processes
                } else {
                    // Follows the system: processes the app's audio where it plays,
                    // and copies what reaches the default device to the extra outputs.
                    if settings.needsProcessing {
                        for uid in [defaultUID] + app.playsOn where outputs.contains(uid) {
                            add(source, to: uid, tapping: app.processes, on: uid, mute: .muted)
                        }
                        takenOver += app.processes
                    }
                    if settings.needsProcessing || !extras.isEmpty {
                        for uid in extras + (settings.excludeFromGlobal ? [] : globalExtras) where uid != defaultUID {
                            add(source, to: uid, tapping: app.processes, on: defaultUID, mute: .unmuted)
                        }
                        unmirrored += app.processes
                    }
                }
                if settings.excludeFromGlobal { unmirrored += app.processes }
            }
        }

        let excluded = Set(own + takenOver)
        // Every output playing applies its own balance, equalizer and, without a volume control, FreeAudio's level.
        for uid in [defaultUID] + globalExtras {
            let settings = state.devices[uid] ?? DeviceAudioSettings()
            guard settings.needsProcessing else { continue }
            add(.system, to: uid, tapping: Array(excluded), on: uid, mute: settings.holdsBackSource ? .muted : .mutedWhenTapped)
        }
        let mirrorExcluded = Array(excluded.union(unmirrored))
        for uid in globalExtras {
            add(.system, to: uid, tapping: mirrorExcluded, on: defaultUID, mute: .unmuted)
        }
        return specs
    }

    /// Where an app plays, from the devices its processes report now, with when each was last seen. A device it
    /// left keeps its route briefly while the last of the app's audio there drains, then loses it, so a route never
    /// follows an app to wherever it once played. A paused app reports no device and is still where it was.
    static func devicesInUse(seen: [String: Date], current: [String], now: Date) -> [String: Date] {
        guard !current.isEmpty else { return seen }
        var seen = seen
        for uid in current { seen[uid] = now }
        return seen.filter { now.timeIntervalSince($0.value) < drainTime }
    }

    static let drainTime: TimeInterval = 3
}
