import SwiftUI

@main
struct FreeAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TrayView()
                .environmentObject(appDelegate.audio)
                .environmentObject(appDelegate.language)
                .environmentObject(appDelegate.updater)
        } label: {
            MenuBarLabel(audio: appDelegate.audio)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let language = LanguageSettings()
    let updater = Updater()
    private(set) lazy var audio = AudioController(engineEnabled: Self.audioEnabled)
    private(set) lazy var shortcuts = Shortcuts(registers: Self.audioEnabled)

    #if DEBUG
    /// `defaults write <bundle id> DebugNoAudio -bool true` runs a copy that leaves devices and apps alone, e.g. to
    /// try an update next to the copy in use.
    private static let audioEnabled = !UserDefaults.standard.bool(forKey: "DebugNoAudio")
    #else
    private static let audioEnabled = true
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when started without the app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
        SettingsWindow.shared.configure(audio: audio, language: language, updater: updater, shortcuts: shortcuts)
        shortcuts.perform = { [weak self] action in self?.runShortcut(action) }
        updater.start()
    }

    private func runShortcut(_ action: ShortcutAction) {
        let result = audio.applyShortcut(action)
        guard shortcuts.settings.showsOSD else { return }
        if let result {
            OSD.shared.show(
                symbol: result.muted ? "mic.slash.fill" : "mic.fill", tint: result.muted ? .red : .green,
                title: L(result.muted ? "osd.mic_muted" : "osd.mic_on"), detail: result.device.name
            )
        } else {
            OSD.shared.show(symbol: "mic.slash", tint: .secondary, title: L("osd.no_mic"), detail: nil)
        }
    }

    /// Opening FreeAudio again (Finder, Spotlight, Launchpad) shows Settings; that also helps when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }
}

/// Observes the controller so the menu bar icon follows the microphone.
private struct MenuBarLabel: View {
    @ObservedObject var audio: AudioController

    var body: some View {
        MenuBarIcon(state: audio.microphoneState)
    }
}
