import CoreAudio
import Testing
@testable import FreeAudio

@Suite struct RoutePlanTests {
    private let speakers = "BuiltInSpeakerDevice"
    private let headphones = "BuiltInHeadphoneOutputDevice"
    private let tv = "HDMI-TV"
    private let own: [AudioObjectID] = [1]

    private func plan(
        _ state: PersistedState, defaultUID: String? = nil, apps: [RoutePlan.App] = [], silenced: Set<String> = []
    ) -> [RouteKey: RouteSpec] {
        RoutePlan.routes(
            defaultUID: defaultUID ?? speakers, outputs: [speakers, headphones, tv], silenced: silenced,
            state: state, apps: apps, own: own
        )
    }

    private func app(_ id: String = "music", playsOn: [String] = [], missing: Bool = false) -> RoutePlan.App {
        RoutePlan.App(id: id, processes: [20, 21], playsOn: playsOn, outputMissing: missing)
    }

    private func mirroring(to devices: [String]) -> PersistedState {
        var state = PersistedState()
        state.globalMultiOutput = true
        state.globalOutputUIDs = devices
        return state
    }

    @Test func globalMultiOutputCopiesTheDefaultDevice() {
        let routes = plan(mirroring(to: [tv]))
        #expect(routes.count == 1)
        let copy = routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: speakers)]
        #expect(copy?.mute == .unmuted && copy?.processes == own)
    }

    @Test func turningGlobalMultiOutputOffLeavesNoCopy() {
        var state = mirroring(to: [tv, headphones])
        state.globalMultiOutput = false
        var settings = AppAudioSettings()
        settings.volume = 0.5
        state.apps["music"] = settings
        let routes = plan(state, apps: [app()])
        #expect(routes.keys.allSatisfy { $0.deviceUID == speakers })
        #expect(routes.count == 1)
    }

    @Test func theDefaultDeviceIsNeverACopyOfItself() {
        // Checked on the headphones, then the headphones became the output.
        #expect(plan(mirroring(to: [headphones]), defaultUID: headphones).isEmpty)
    }

    @Test func aProcessedAppIsCopiedFromTheDefaultDeviceAlongsideItsOwnRoute() {
        // Both go to the TV: the app processed where it plays, and its copy of the default device's audio. Keyed by
        // device alone, one of them used to be dropped.
        var state = mirroring(to: [tv])
        var settings = AppAudioSettings()
        settings.volume = 0.5
        state.apps["music"] = settings
        let routes = plan(state, apps: [app(playsOn: [tv])])
        let processed = routes[RouteKey(source: .app("music"), deviceUID: tv, tapDeviceUID: tv)]
        let copied = routes[RouteKey(source: .app("music"), deviceUID: tv, tapDeviceUID: speakers)]
        #expect(processed?.mute == .muted && copied?.mute == .unmuted)
        #expect(routes[RouteKey(source: .app("music"), deviceUID: speakers, tapDeviceUID: speakers)]?.mute == .muted)
        // The system copy leaves the app to its own routes.
        #expect(routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: speakers)]?.processes == [1, 20, 21])
    }

    @Test func anAppKeptOutOfTheMirrorIsNotCopied() {
        var state = mirroring(to: [tv])
        var settings = AppAudioSettings()
        settings.excludeFromGlobal = true
        state.apps["call"] = settings
        let routes = plan(state, apps: [app("call")])
        #expect(routes.count == 1)
        #expect(routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: speakers)]?.processes == [1, 20, 21])
    }

    @Test func aMovedAppPlaysOnlyWhereItWasSent() {
        var state = PersistedState()
        var settings = AppAudioSettings()
        settings.outputUID = headphones
        settings.multiOutput = true
        settings.extraOutputUIDs = [tv, headphones]
        state.apps["music"] = settings
        let routes = plan(state, apps: [app(playsOn: [speakers])])
        #expect(routes[RouteKey(source: .app("music"), deviceUID: headphones, tapDeviceUID: nil)]?.mute == .muted)
        #expect(routes[RouteKey(source: .app("music"), deviceUID: tv, tapDeviceUID: nil)]?.mute == .unmuted)
        #expect(routes.count == 2)
    }

    @Test func anAppsRouteDoesNotFollowItToWhereItOncePlayed() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var seen = RoutePlan.devicesInUse(seen: [:], current: [speakers], now: start)
        // Moved to the headphones: the speakers keep their route while the last audio drains, then lose it.
        seen = RoutePlan.devicesInUse(seen: seen, current: [headphones], now: start.addingTimeInterval(1))
        #expect(Set(seen.keys) == [speakers, headphones])
        seen = RoutePlan.devicesInUse(seen: seen, current: [headphones], now: start.addingTimeInterval(4))
        #expect(Set(seen.keys) == [headphones])
        // Paused for a while: still where it was when it resumes.
        seen = RoutePlan.devicesInUse(seen: seen, current: [], now: start.addingTimeInterval(600))
        #expect(Set(seen.keys) == [headphones])
    }

    @Test func everyOutputPlayingAppliesItsOwnEqualizer() {
        var state = mirroring(to: [tv])
        var settings = DeviceAudioSettings()
        settings.eq.apply(.rock)
        state.devices[tv] = settings
        let routes = plan(state)
        // What reaches the TV from the default device is a copy, rendered with the TV's settings; what plays on
        // the TV itself is processed there.
        #expect(routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: speakers)]?.mute == .unmuted)
        #expect(routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: tv)]?.mute == .mutedWhenTapped)
        #expect(routes[RouteKey(source: .system, deviceUID: speakers, tapDeviceUID: speakers)] == nil)
    }

    @Test func aLevelFreeAudioSetsKeepsTheDeviceMutedFromTheStart() {
        var state = PersistedState()
        var settings = DeviceAudioSettings()
        settings.volume = 0.5
        state.devices[tv] = settings
        let routes = plan(state, defaultUID: tv)
        #expect(routes[RouteKey(source: .system, deviceUID: tv, tapDeviceUID: tv)]?.mute == .muted)
        // Back at 100%: nothing to do.
        state.devices[tv] = nil
        #expect(plan(state, defaultUID: tv).isEmpty)
    }

    @Test func aStandInGetsNothing() {
        #expect(plan(mirroring(to: [tv]), silenced: [tv]).isEmpty)
    }
}
