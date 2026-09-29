import CoreAudio
import Foundation

/// A device macOS keeps switching to however often FreeAudio switches back, e.g. AirPods it routes to while they're in
/// an ear. FreeAudio has stopped switching back, rather than flip between the two, while that device is there; it
/// doesn't try again with it until a device is picked in FreeAudio.
struct YieldedDevice: Equatable {
    let device: AudioDevice
    let chosen: AudioDevice
}

/// A chosen device that isn't connected. Whatever macOS picked in its place stays silenced until it's back.
struct MissingDevice: Equatable {
    let uid: String
    let name: String
    var warned = false
}

enum DeviceLockDecision: Equatable {
    /// The chosen device is in use.
    case keep
    /// Another device took over; go back to the chosen one.
    case switchBack(AudioDeviceID)
    /// The chosen device isn't connected.
    case missing
}

enum DeviceLock {
    /// Only the chosen device, matched by UID, is used. Any switch made elsewhere, e.g. by macOS when headphones
    /// connect, or in Control Center, is undone; the chosen device only changes when it's picked in FreeAudio.
    static func decide(chosenUID: String, devices: [AudioDevice], currentID: AudioDeviceID) -> DeviceLockDecision {
        guard let chosen = devices.first(where: { $0.uid == chosenUID }) else { return .missing }
        return currentID == chosen.id ? .keep : .switchBack(chosen.id)
    }

    /// Switching back sooner than this means something keeps switching away; wait rather than fight it.
    static let minimumSwitchInterval: TimeInterval = 0.5

    /// FreeAudio's switch-backs away from one device, each within `fightWindow` of the one before: the other side
    /// switched away again as soon as FreeAudio switched back.
    struct Fight: Equatable {
        let uid: String
        var switchBacks: Int
        var last: Date
    }

    static let fightWindow: TimeInterval = 2
    /// Switch-backs in a row before FreeAudio stops. macOS routing to AirPods switched back within 0.1 s every time,
    /// and went on until the AirPods disconnected.
    static let fightLimit = 2

    /// The fight once FreeAudio switches back from `awayUID` at `now`.
    static func fight(after previous: Fight?, awayUID: String, now: Date) -> Fight {
        guard let previous, previous.uid == awayUID, now.timeIntervalSince(previous.last) < fightWindow else {
            return Fight(uid: awayUID, switchBacks: 1, last: now)
        }
        return Fight(uid: awayUID, switchBacks: previous.switchBacks + 1, last: now)
    }

    /// Whether to stop instead of switching back this time.
    static func givesUp(_ fight: Fight) -> Bool { fight.switchBacks > fightLimit }
}
