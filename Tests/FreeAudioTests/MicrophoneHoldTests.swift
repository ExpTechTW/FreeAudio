import Foundation
import Testing
@testable import FreeAudio

@Suite struct MicrophoneHoldTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    private func step(muted: Bool, mutedAgo seconds: [TimeInterval]) -> MicrophoneHold.Step {
        MicrophoneHold.step(muted: muted, recentMutes: seconds.map { now.addingTimeInterval(-$0) }, now: now)
    }

    @Test func leavesAMutedMicrophoneAlone() {
        #expect(step(muted: true, mutedAgo: []) == .keep)
        #expect(step(muted: true, mutedAgo: [0.01, 0.02]) == .keep)
    }

    @Test func mutesItAgainWhenSomethingUnmutesIt() {
        // Siri starting to listen during playback, or a call's voice processing starting on it.
        #expect(step(muted: false, mutedAgo: []) == .mute)
        #expect(step(muted: false, mutedAgo: [2, 1]) == .mute)
    }

    @Test func waitsRatherThanSpinning() throws {
        guard case .retry(let delay) = step(muted: false, mutedAgo: [0.04]) else { Issue.record("muted again at once"); return }
        #expect(abs(delay - (MicrophoneHold.minimumInterval - 0.04)) < 1e-6)
    }

    @Test func holdsTheVolumeAtZeroWhenItKeepsBeingUnmuted() {
        #expect(step(muted: false, mutedAgo: [2.5, 2, 1.5, 1, 0.5]) == .muteAndPark)
        // Unmutes spread out over time are separate events, not a fight.
        #expect(step(muted: false, mutedAgo: [30, 20, 10, 5, 4]) == .mute)
    }

    @Test func recordsOnlyTheMutesThatStillCount() {
        let recent = [now.addingTimeInterval(-10), now.addingTimeInterval(-1)]
        #expect(MicrophoneHold.recording(now, after: recent) == [now.addingTimeInterval(-1), now])
    }

    @Test func savedStateWithoutHeldMicrophonesIsTakenOverOnce() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"deviceLevels":{"input:mic":{"volume":1,"muted":true}}}"#.utf8))
        #expect(old.mutedMicrophones == nil && old.parkedMicrophones.isEmpty)
        var state = PersistedState()
        state.mutedMicrophones = ["BuiltInMicrophoneDevice"]
        state.parkedMicrophones = ["usb-mic": 0.7]
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(decoded.mutedMicrophones == ["BuiltInMicrophoneDevice"] && decoded.parkedMicrophones == ["usb-mic": 0.7])
    }
}
