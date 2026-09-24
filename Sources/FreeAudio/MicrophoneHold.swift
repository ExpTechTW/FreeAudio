import Foundation

/// A microphone muted in FreeAudio stays muted until it's unmuted in FreeAudio.
///
/// macOS unmutes microphones by itself: the built-in one while Siri listens during playback on the built-in
/// speakers, and any microphone when an app opens or closes a voice-processing session on it, as a call does when
/// its audio moves to another device. Each time, FreeAudio mutes it again.
enum MicrophoneHold {
    enum Step: Equatable {
        /// It's muted.
        case keep
        /// Something unmuted it: mute it again.
        case mute
        /// It keeps being unmuted: mute it again and hold its volume at zero as well, which nothing else changes.
        case muteAndPark
        /// It was muted again a moment ago; try again after this long rather than spin.
        case retry(after: TimeInterval)
    }

    static let minimumInterval: TimeInterval = 0.1
    /// This many mutes within `window` means something keeps unmuting it.
    static let persistentCount = 6
    static let window: TimeInterval = 3

    /// `recentMutes` are the times FreeAudio muted it again, oldest first.
    static func step(muted: Bool, recentMutes: [Date], now: Date) -> Step {
        guard !muted else { return .keep }
        let recent = recentMutes.filter { now.timeIntervalSince($0) < window }
        if let last = recent.last, now.timeIntervalSince(last) < minimumInterval {
            return .retry(after: minimumInterval - now.timeIntervalSince(last))
        }
        return recent.count + 1 >= persistentCount ? .muteAndPark : .mute
    }

    /// The mutes that still count once it's muted again `now`.
    static func recording(_ now: Date, after recentMutes: [Date]) -> [Date] {
        recentMutes.filter { now.timeIntervalSince($0) < window } + [now]
    }
}
