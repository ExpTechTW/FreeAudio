import CoreAudio
import Foundation

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
}
