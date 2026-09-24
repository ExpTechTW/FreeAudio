import AppKit
import Foundation

/// The "System Audio Recording" privacy permission that process taps need.
/// Without it taps deliver silence, so routes would mute the apps they touch.
enum AudioCapturePermission {
    enum Status: Equatable {
        case authorized, denied, notDetermined
        /// The status can't be read on this system; routes are attempted and macOS prompts by itself.
        case unknown
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture"
    private nonisolated(unsafe) static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(framework, "TCCAccessPreflight") else { return .unknown }
        return switch unsafeBitCast(symbol, to: Preflight.self)(service as CFString, nil) {
        case 0: .authorized
        case 1: .denied
        default: .notDetermined
        }
    }

    /// Shows the system prompt. Returns false when the prompt can't be requested.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let symbol = dlsym(framework, "TCCAccessRequest") else { return false }
        unsafeBitCast(symbol, to: Request.self)(service as CFString, nil) { completion($0) }
        return true
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
