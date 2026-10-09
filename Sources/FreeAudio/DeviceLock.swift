import CoreAudio
import Foundation

/// A device something else switched to while devices are kept, e.g. AirPods macOS takes as they come out of their
/// case. FreeAudio goes along with the switch rather than fight it, but keeps the device silent until the user unlocks
/// it, which makes it the chosen device at its remembered level, or switches back to the chosen one.
struct LockedDevice: Equatable {
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
    /// Another device is in use while the chosen one, this one, is connected; `DeviceLock.respond` says what to do.
    case switchBack(AudioDeviceID)
    /// The chosen device isn't connected.
    case missing
}

enum DeviceLock {
    /// Only the chosen device, matched by UID, is used. A switch made elsewhere, e.g. by macOS when headphones connect,
    /// or in Control Center, doesn't change it; the chosen device only changes when it's picked in FreeAudio.
    static func decide(chosenUID: String, devices: [AudioDevice], currentID: AudioDeviceID) -> DeviceLockDecision {
        guard let chosen = devices.first(where: { $0.uid == chosenUID }) else { return .missing }
        return currentID == chosen.id ? .keep : .switchBack(chosen.id)
    }

    enum Response: Equatable {
        /// FreeAudio puts the chosen device back.
        case switchBack
        /// Go along with the switch, keeping the device silent until it's unlocked (`LockedDevice`).
        case lock
        /// It's locked already: keep it silent.
        case keepLocked
    }

    /// What to do about another device in use while the chosen one is connected. FreeAudio's own putting back of the
    /// chosen device after launch, or once it's connected again (`restoring`), goes ahead, as it does when nothing is in
    /// use; any other switch, e.g. macOS taking AirPods out of their case or a pick in Control Center, is followed and
    /// locked rather than undone, which macOS would only undo again.
    static func respond(to currentUID: String?, locked lockedUID: String?, restoring: Bool) -> Response {
        guard let currentUID, !restoring else { return .switchBack }
        return currentUID == lockedUID ? .keepLocked : .lock
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
