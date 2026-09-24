import SwiftUI

@main
struct FreeAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TrayView()
                .environmentObject(appDelegate.audio)
                .environmentObject(appDelegate.language)
        } label: {
            MenuBarLabel(audio: appDelegate.audio)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let language = LanguageSettings()
    private(set) lazy var audio = AudioController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when started without the app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
        _ = audio
    }

    /// Opening FreeAudio again (Finder, Spotlight, Launchpad) shows Settings; that also helps when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show(audio: audio, language: language)
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
