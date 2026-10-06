import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutsPage: View {
    @EnvironmentObject private var shortcuts: Shortcuts

    var body: some View {
        Form {
            PageHeader(page: .shortcuts)

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        Text(action.title)
                        if shortcuts.unavailable.contains(action) {
                            Text(L("shortcuts.unavailable")).foregroundStyle(.orange)
                        } else {
                            Text(action.hint)
                        }
                    }
                }
            } header: {
                Text(L("shortcuts.microphone"))
            } footer: {
                Text(L("shortcuts.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: Binding(get: { shortcuts.settings.showsOSD }, set: { shortcuts.setShowsOSD($0) })) {
                    Text(L("shortcuts.osd"))
                    Text(L("shortcuts.osd_hint"))
                }
                if shortcuts.settings.showsOSD {
                    HStack(spacing: 12) {
                        OSDView(symbol: "mic.slash.fill", tint: .red, title: L("osd.mic_muted"), detail: L("shortcuts.osd_sample_device"))
                        OSDView(symbol: "mic.fill", tint: .green, title: L("osd.mic_on"), detail: L("shortcuts.osd_sample_device"))
                    }
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A shortcut field: shows the keys, and records new ones once clicked. Esc cancels, Delete clears.
private struct ShortcutRecorder: View {
    @EnvironmentObject private var shortcuts: Shortcuts
    let action: ShortcutAction
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        let combo = shortcuts.settings[action]
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? (problem ?? L("shortcuts.press_keys")) : combo?.display ?? L("shortcuts.none"))
                    .font(recording || combo == nil ? .body : .body.monospaced())
                    .foregroundStyle(recording ? (problem == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange)) : combo == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(minWidth: 130)
            }
            .help(L(recording ? "shortcuts.recording_help" : "shortcuts.record_help"))
            .accessibilityLabel(LF("shortcuts.a11y", action.title, combo?.display ?? L("shortcuts.none")))
            // Always there, so the fields line up; only usable with a shortcut set.
            let clearable = combo != nil && !recording
            Button {
                shortcuts.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("shortcuts.clear"))
            .accessibilityLabel(LF("shortcuts.clear_a11y", action.title))
            .opacity(clearable ? 1 : 0)
            .disabled(!clearable)
            .accessibilityHidden(!clearable)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        shortcuts.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch ShortcutRecording.decide(
                keyCode: Int(event.keyCode), flags: event.modifierFlags, key: event.charactersIgnoringModifiers, for: action, in: shortcuts.settings
            ) {
            case .cancel:
                stop()
            case .clear:
                shortcuts.set(nil, for: action)
                stop()
            case .set(let combo):
                shortcuts.set(combo, for: action)
                stop()
            case .reject(let reason):
                problem = reason
                NSSound.beep()
            }
            // Recording takes every key, so typing doesn't reach the window.
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        problem = nil
        shortcuts.resume()
    }
}
