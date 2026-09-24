import AppKit
import Combine
import SwiftUI

/// The Settings window, managed directly: SwiftUI's Settings scene doesn't reliably open, or come to the front,
/// from a menu bar app.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var titleUpdates: AnyCancellable?

    func show(audio: AudioController, language: LanguageSettings, updater: Updater) {
        let window = self.window ?? makeWindow(audio: audio, language: language, updater: updater)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Visible even when macOS doesn't hand FreeAudio the focus.
        window.orderFrontRegardless()
    }

    private func makeWindow(audio: AudioController, language: LanguageSettings, updater: Updater) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsRoot(audio: audio, language: language, updater: updater))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = L("window.settings_title")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 620))
        // The published value changes before the strings do; update the title once they have.
        titleUpdates = language.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak window] _ in
                MainActor.assumeIsolated { window?.title = L("window.settings_title") }
            }
        return window
    }
}

private struct SettingsRoot: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var language: LanguageSettings
    let updater: Updater

    var body: some View {
        SettingsView()
            .environmentObject(audio)
            .environmentObject(language)
            .environmentObject(updater)
            .environment(\.locale, language.language.locale)
    }
}
