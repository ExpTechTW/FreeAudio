import SwiftUI

/// What the panel shows: the overview, or everything about one app or output device.
private enum TrayPage: Equatable {
    case overview
    case app(String)
    case device(String)
}

struct TrayView: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var language: LanguageSettings
    @State private var page = TrayPage.overview
    /// Last measured content height; remembered so the panel opens at the right size.
    @AppStorage("tray.contentHeight") private var contentHeight = 420.0

    var body: some View {
        // Scrolls only when the panel would be taller than the screen.
        ScrollView(.vertical) {
            current
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - contentHeight) > 0.5 { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .environment(\.locale, language.language.locale)
        // Rebuilds every string when the language changes.
        .id(language.language)
        .frame(width: Metrics.panelWidth)
        // The overview again the next time the panel opens.
        .onDisappear { page = .overview }
    }

    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    /// A page whose app quit or whose device went away falls back to the overview.
    @ViewBuilder private var current: some View {
        switch page {
        case .app(let id):
            if let app = audio.apps.first(where: { $0.id == id }) {
                AppPage(app: app) { go(.overview) }
            } else {
                Overview(open: go)
            }
        case .device(let uid):
            if let device = audio.outputDevices.first(where: { $0.uid == uid }) {
                DevicePage(device: device) { go(.overview) }
            } else {
                Overview(open: go)
            }
        case .overview:
            Overview(open: go)
        }
    }

    private func go(_ next: TrayPage) {
        withAnimation(.snappy(duration: 0.2)) { page = next }
    }
}

// MARK: - Overview

private struct Overview: View {
    let open: (TrayPage) -> Void

    var body: some View {
        VStack(spacing: 10) {
            OutputCard(open: open)
            InputCard()
            AppsCard(open: open)
            Footer()
        }
    }
}

private struct OutputCard: View {
    @EnvironmentObject private var audio: AudioController
    let open: (TrayPage) -> Void

    var body: some View {
        let main = audio.defaultOutput
        // The system's output and the ones checked to play along with it, like AirPlay speakers.
        let playing = [main].compactMap { $0 } + audio.extraOutputs
        let others = audio.outputDevices.filter { !playing.contains($0) }
        Card(title: L("section.output")) {
            DeviceNotices(direction: .output, selected: main)
            if playing.isEmpty {
                Text(L("device.output_not_found")).foregroundStyle(.secondary)
            }
            ForEach(playing) { device in
                LevelRow(device: device, direction: .output, isDefault: device == main) { open(.device(device.uid)) } accessory: {
                    // The last output playing can't be unchecked.
                    CheckButton(checked: true, label: LF("multi.remove_device", device.name)) { audio.toggleOutput(device) }
                        .disabled(playing.count < 2)
                }
            }
            if !others.isEmpty {
                Divider()
                ForEach(others) { device in
                    HStack(spacing: 4) {
                        ChoiceRow(device: device) { audio.select(device, .output) }
                        CheckButton(checked: false, label: LF("multi.add_device", device.name)) { audio.toggleOutput(device) }
                    }
                }
            }
        }
    }
}

private struct InputCard: View {
    @EnvironmentObject private var audio: AudioController

    var body: some View {
        let main = audio.defaultInput
        let others = audio.inputDevices.filter { $0 != main }
        Card(title: L("section.input")) {
            DeviceNotices(direction: .input, selected: main)
            if let main {
                LevelRow(device: main, direction: .input, isDefault: true, open: nil) { EmptyView() }
            } else {
                Text(L("device.input_not_found")).foregroundStyle(.secondary)
            }
            if !others.isEmpty {
                Divider()
                ForEach(others) { device in
                    ChoiceRow(device: device) { audio.select(device, .input) }
                }
            }
        }
    }
}

/// A device in use: its name and what FreeAudio does to its sound, its level, mute and volume slider.
private struct LevelRow<Accessory: View>: View {
    @EnvironmentObject private var audio: AudioController
    let device: AudioDevice
    let direction: DeviceDirection
    /// The system default rather than an extra output; only it stands in for a missing device.
    let isDefault: Bool
    /// Opens the device's page; outputs have one.
    let open: (() -> Void)?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        let level = audio.level(of: device, direction)
        let disabled = isDefault && audio.isDisabled(direction)
        let summary = direction == .output ? audio.deviceSettings(for: device.uid).summary : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let label = HStack(spacing: 8) {
                    DeviceIcon(symbol: device.symbol, selected: true)
                    NameAndSummary(name: device.name, summary: summary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .help(device.name)
                // Only a device with a page of its own is a button; a disabled one would look unavailable.
                if let open {
                    Button(action: open) { label }.buttonStyle(.plain)
                } else {
                    label
                }
                Text(percent(level.volume)).percentStyle()
                IconButton(
                    symbol: direction == .output ? speakerSymbol(volume: level.volume, muted: level.muted) : level.muted ? "mic.slash.fill" : "mic.fill",
                    help: level.muted ? L("action.unmute") : L("action.mute"),
                    label: LF(level.muted ? "a11y.unmute" : "a11y.mute", device.name)
                ) {
                    audio.toggleMute(device, direction)
                }
                .disabled(disabled)
                if let open { DetailButton(label: LF("a11y.device_processing", device.name), action: open) }
                accessory
            }
            Slider(value: Binding(get: { level.volume }, set: { audio.setVolume($0, for: device, direction) }), in: 0...1) {
                Text(LF("a11y.volume", device.name))
            }
            .labelsHidden()
            // Gray while muted; dragging still works and unmutes, like the system controls.
            .tint(level.muted ? Color.soundOff : nil)
            .disabled(!level.adjustable || disabled)
            .help(percent(level.volume))
            .padding(.leading, Metrics.icon + 8)
        }
    }
}

/// A name, with what's applied to it in small print underneath.
/// Something wrong with a row, shown in place of its summary.
private struct RowWarning {
    let symbol: String
    let tint: Color
    let text: String
}

private struct NameAndSummary: View {
    let name: String
    let summary: String?
    var warning: RowWarning?
    var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if playing {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            if let warning {
                Label(warning.text, systemImage: warning.symbol)
                    .font(.caption)
                    .foregroundStyle(warning.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(warning.text)
            } else if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// A device that isn't in use; choosing it makes it the system's.
private struct ChoiceRow: View {
    let device: AudioDevice
    let action: () -> Void

    var body: some View {
        MenuRow(action: action) {
            HStack(spacing: 8) {
                DeviceIcon(symbol: device.symbol)
                Text(device.name).lineLimit(1).truncationMode(.middle)
            }
        }
        .help(device.name)
    }
}

/// While the chosen device is missing that direction is off; after something else switched devices, FreeAudio
/// switched back.
private struct DeviceNotices: View {
    @EnvironmentObject private var audio: AudioController
    let direction: DeviceDirection
    let selected: AudioDevice?

    var body: some View {
        if let missing = audio.missingDevices[direction] {
            Notice(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                title: LF("guard.missing_title", missing.name),
                text: L(direction == .output ? "guard.output_disabled" : "guard.input_disabled")
            ) {
                if let selected {
                    Button(LF("guard.use_current", selected.name)) { audio.useCurrentDevice(direction) }
                }
            }
        } else if let blocked = audio.blockedDevices[direction], let selected {
            Notice(symbol: "lock.fill", tint: .accentColor, text: LF("guard.blocked", blocked.name, selected.name)) {
                HStack(spacing: 8) {
                    Button(LF("guard.use_current", blocked.name)) {
                        let devices = direction == .output ? audio.outputDevices : audio.inputDevices
                        if let device = devices.first(where: { $0.uid == blocked.uid }) { audio.select(device, direction) }
                    }
                    Button(L("guard.dismiss")) { audio.dismissBlocked(direction) }
                }
            }
        }
    }
}

private struct AppsCard: View {
    @EnvironmentObject private var audio: AudioController
    @Environment(\.locale) private var locale
    let open: (TrayPage) -> Void

    var body: some View {
        Card(title: L("tray.app_volume")) {
            if !audio.state.perAppEnabled {
                HStack(spacing: 8) {
                    Text(L("tray.per_app_off")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(L("action.turn_on")) { audio.setPerAppEnabled(true) }
                        .controlSize(.small)
                }
            } else {
                switch audio.permission {
                case .notDetermined:
                    Notice(symbol: "lock.shield", tint: .accentColor, text: L("permission.onboarding")) {
                        Button(L("permission.request"), action: audio.requestPermission)
                            .buttonStyle(.borderedProminent)
                    }
                case .denied:
                    Notice(symbol: "lock.fill", tint: .orange, text: L("permission.denied")) {
                        Button(L("permission.open_settings"), action: audio.openPrivacySettings)
                    }
                case .authorized, .unknown:
                    EmptyView()
                }
                if !audio.conflictingApps.isEmpty {
                    Notice(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: LF("conflict.warning", audio.conflictingApps.formatted(.list(type: .and).locale(locale)))
                    ) { EmptyView() }
                }
                if audio.apps.isEmpty {
                    Text(L("tray.no_playing_apps")).foregroundStyle(.secondary)
                }
                ForEach(audio.apps) { app in
                    AppRow(app: app) { open(.app(app.id)) }
                }
                if let error = audio.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject private var audio: AudioController
    let app: AudioApp
    let open: () -> Void

    var body: some View {
        let settings = audio.settings(for: app)
        let warning = settings.outputUID.flatMap { uid in
            audio.appOutputMissing(app.id)
                ? RowWarning(symbol: "exclamationmark.triangle.fill", tint: .red, text: LF("guard.app_missing", audio.deviceName(uid: uid)))
                : nil
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        AppIcon(app: app)
                        NameAndSummary(name: app.name, summary: settings.summary(deviceName: audio.deviceName(uid:)), warning: warning, playing: app.isPlaying)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(app.name)
                Text(percent(settings.volume)).percentStyle()
                IconButton(
                    symbol: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: settings.muted ? L("action.unmute") : L("action.mute"),
                    label: LF(settings.muted ? "a11y.unmute" : "a11y.mute", app.name)
                ) {
                    audio.updateSettings(for: app) { $0.muted.toggle() }
                }
                DetailButton(label: LF("a11y.app_settings", app.name), action: open)
            }
            AppVolumeSlider(app: app, settings: settings)
                .padding(.leading, Metrics.icon + 8)
        }
        .contextMenu {
            Button(L("app.reset")) { audio.resetSettings(forApp: app.id) }
                .disabled(audio.state.apps[app.id] == nil)
        }
    }
}


/// 0–200%; the tick in the middle is the app's own level.
private struct AppVolumeSlider: View {
    @EnvironmentObject private var audio: AudioController
    let app: AudioApp
    let settings: AppAudioSettings

    var body: some View {
        Slider(
            value: Binding(
                get: { settings.volume },
                set: { value in
                    let volume = abs(value - 1) < 0.03 ? 1 : (value * 100).rounded() / 100
                    guard volume != settings.volume else { return }
                    // Like the device sliders, moving a muted app's slider unmutes it.
                    audio.updateSettings(for: app) { $0.volume = volume; $0.muted = false }
                }
            ),
            in: 0...2
        ) {
            Text(app.name)
        } ticks: {
            SliderTick(1)
        }
        .labelsHidden()
        .tint(settings.muted || audio.appOutputMissing(app.id) ? Color.soundOff : nil)
        .help(percent(settings.volume))
    }
}

private struct Footer: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var language: LanguageSettings
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(LF("settings.version", updater.build.label))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ReleaseBadge(prerelease: updater.build.isPrerelease)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            // Only when a newer build is out.
            if let release = updater.available {
                MenuRow {
                    updater.showAvailable()
                } label: {
                    HStack {
                        Text(updaterTitle(release))
                        Spacer()
                        updateProgress
                    }
                }
                .disabled(updater.isBusy)
            }
            MenuRow(shortcut: KeyboardShortcut(",")) {
                SettingsWindow.shared.show(audio: audio, language: language, updater: updater)
            } label: {
                ShortcutLabel(title: L("action.settings"), keys: "⌘,")
            }
            MenuRow(shortcut: KeyboardShortcut("q")) {
                NSApp.terminate(nil)
            } label: {
                ShortcutLabel(title: L("action.quit"), keys: "⌘Q")
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var updateProgress: some View {
        switch updater.phase {
        case .downloading(let percent):
            ProgressView(value: Double(percent), total: 100).progressViewStyle(.circular).controlSize(.small)
        case .installing:
            ProgressView().controlSize(.small)
        default:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        }
    }

    private func updaterTitle(_ release: Release) -> String {
        switch updater.phase {
        case .downloading(let percent): LF("update.downloading", "\(percent)%")
        case .installing: L("update.installing")
        default: LF("update.tray", release.label)
        }
    }
}

/// A menu item's title with its keyboard shortcut on the right, as menus show them.
private struct ShortcutLabel: View {
    let title: String
    let keys: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }
}

// MARK: - App and device pages

/// Back to the overview, and what the page is about.
private struct PageTitle<Icon: View>: View {
    let title: String
    let subtitle: String
    let back: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: back) {
                Label(L("tray.back"), systemImage: "chevron.left").font(.callout.weight(.medium))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct AppPage: View {
    @EnvironmentObject private var audio: AudioController
    let app: AudioApp
    let back: () -> Void

    var body: some View {
        let settings = audio.settings(for: app)
        // Where the app plays: its own device if that's connected, otherwise the system's.
        let primary = settings.outputUID.flatMap { uid in audio.outputDevices.contains { $0.uid == uid } ? uid : nil } ?? audio.defaultOutput?.uid
        let others = audio.outputDevices.filter { $0.uid != primary }
        VStack(alignment: .leading, spacing: 10) {
            PageTitle(title: app.name, subtitle: L(app.isPlaying ? "app.playing" : "app.not_playing"), back: back) {
                AppIcon(app: app, size: 32)
            }

            Card(title: L("detail.volume")) {
                HStack(spacing: 8) {
                    AppVolumeSlider(app: app, settings: settings)
                    Text(percent(settings.volume)).percentStyle()
                    IconButton(
                        symbol: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        help: settings.muted ? L("action.unmute") : L("action.mute"),
                        label: LF(settings.muted ? "a11y.unmute" : "a11y.mute", app.name)
                    ) {
                        audio.updateSettings(for: app) { $0.muted.toggle() }
                    }
                }
            }

            Card(title: L("section.output")) {
                LabeledRow(L("app.output_device")) {
                    Picker(L("app.output_device"), selection: Binding(get: { settings.outputUID }, set: { uid in audio.updateSettings(for: app) { $0.outputUID = uid } })) {
                        Label(L("device.follow_system"), systemImage: "rectangle.on.rectangle").tag(String?.none)
                        Divider()
                        ForEach(audio.outputDevices) { device in
                            Label(device.name, systemImage: device.symbol).tag(Optional(device.uid))
                        }
                        if let uid = settings.outputUID, !audio.outputDevices.contains(where: { $0.uid == uid }) {
                            Text(LF("device.unavailable", audio.deviceName(uid: uid))).tag(Optional(uid))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                if !others.isEmpty {
                    Text(L("detail.also_play_on")).font(.caption).foregroundStyle(.secondary)
                    ForEach(others) { device in
                        DeviceCheckRow(device: device, checked: settings.multiOutput && settings.extraOutputUIDs.contains(device.uid)) {
                            audio.updateSettings(for: app) { $0.toggleExtraOutput(device.uid) }
                        }
                    }
                }
                // Only matters while sound plays on several devices, or to undo it.
                if !audio.extraOutputs.isEmpty || settings.excludeFromGlobal {
                    SwitchRow(L("app.exclude_global"), isOn: settings.excludeFromGlobal) { on in
                        audio.updateSettings(for: app) { $0.excludeFromGlobal = on }
                    }
                }
            }

            Card(title: L("detail.sound")) {
                LabeledRow(L("balance.help")) {
                    BalanceSlider(value: settings.balance) { value in audio.updateSettings(for: app) { $0.balance = value } }
                }
            }

            Card {
                EqualizerPanel(settings: settings.eq) { eq in audio.updateSettings(for: app) { $0.eq = eq } }
            }

            Button(L("app.reset"), role: .destructive) { audio.resetSettings(forApp: app.id) }
                .buttonStyle(.borderless)
                .disabled(audio.state.apps[app.id] == nil)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct DevicePage: View {
    @EnvironmentObject private var audio: AudioController
    let device: AudioDevice
    let back: () -> Void

    var body: some View {
        let settings = audio.deviceSettings(for: device.uid)
        let level = audio.level(of: device, .output)
        VStack(alignment: .leading, spacing: 10) {
            PageTitle(title: device.name, subtitle: L("device.processing_hint"), back: back) {
                DeviceIcon(symbol: device.symbol, selected: true)
            }

            Card(title: L("detail.volume")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { level.volume }, set: { audio.setVolume($0, for: device, .output) }), in: 0...1) {
                        Text(LF("a11y.volume", device.name))
                    }
                    .labelsHidden()
                    .tint(level.muted ? Color.soundOff : nil)
                    .disabled(!level.adjustable)
                    Text(percent(level.volume)).percentStyle()
                    IconButton(
                        symbol: speakerSymbol(volume: level.volume, muted: level.muted),
                        help: level.muted ? L("action.unmute") : L("action.mute"),
                        label: LF(level.muted ? "a11y.unmute" : "a11y.mute", device.name)
                    ) {
                        audio.toggleMute(device, .output)
                    }
                }
            }

            Card(title: L("detail.sound")) {
                LabeledRow(L("balance.help")) {
                    BalanceSlider(value: settings.balance) { value in audio.updateDeviceSettings(for: device) { $0.balance = value } }
                }
            }

            Card {
                EqualizerPanel(settings: settings.eq) { eq in audio.updateDeviceSettings(for: device) { $0.eq = eq } }
            }

            Button(L("detail.reset_device"), role: .destructive) { audio.resetDeviceSettings(uid: device.uid) }
                .buttonStyle(.borderless)
                .disabled(settings.isDefault)
                .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
/// Lets layout snapshots show the page of an app or an output device.
struct TrayPagePreview: View {
    @EnvironmentObject private var audio: AudioController
    var appID: String?
    var deviceUID: String?

    var body: some View {
        Group {
            if let app = audio.apps.first(where: { $0.id == appID }) {
                AppPage(app: app) {}
            } else if let device = audio.outputDevices.first(where: { $0.uid == deviceUID }) {
                DevicePage(device: device) {}
            }
        }
        .padding(12)
        .frame(width: Metrics.panelWidth)
    }
}
#endif
