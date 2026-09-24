import SwiftUI

struct TrayView: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var language: LanguageSettings
    @AppStorage("tray.inputExpanded") private var inputExpanded = true
    @AppStorage("tray.outputExpanded") private var outputExpanded = true
    @AppStorage("tray.appsExpanded") private var appsExpanded = true
    @AppStorage("tray.outputDetail") private var showsOutputDetail = false
    @AppStorage("tray.expandedApp") private var expandedApp = ""
    /// Last measured content height; remembered so the panel opens at the right size.
    @AppStorage("tray.contentHeight") private var contentHeight = 420.0

    var body: some View {
        // Scrolls only when the panel would be taller than the screen.
        ScrollView(.vertical) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - contentHeight) > 0.5 { contentHeight = height }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .environment(\.locale, language.language.locale)
        // Rebuilds every string when the language changes.
        .id(language.language)
        .frame(width: Metrics.panelWidth)
    }

    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            DeviceSection(direction: .input, expanded: $inputExpanded, showsDetail: .constant(false))
            DeviceSection(direction: .output, expanded: $outputExpanded, showsDetail: $showsOutputDetail)
            Divider().padding(.vertical, 4)
            MultiOutputSection()
            AppsSection(expanded: $appsExpanded, expandedApp: $expandedApp)
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRowMenu {
                Picker(L("language.title"), selection: $language.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack {
                    Text(L("language.title"))
                    Spacer()
                    Text(language.language.displayName).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            MenuRow(shortcut: KeyboardShortcut(",")) {
                SettingsWindow.shared.show(audio: audio, language: language)
            } label: {
                Text(L("action.settings"))
            }
            MenuRow(shortcut: KeyboardShortcut("q")) {
                NSApp.terminate(nil)
            } label: {
                Text(L("action.quit"))
            }
        }
    }
}

// MARK: - Devices

private struct DeviceSection: View {
    @EnvironmentObject private var audio: AudioController
    let direction: DeviceDirection
    @Binding var expanded: Bool
    @Binding var showsDetail: Bool

    var body: some View {
        let devices = direction == .input ? audio.inputDevices : audio.outputDevices
        let selected = direction == .input ? audio.defaultInput : audio.defaultOutput
        let others = devices.filter { $0.id != selected?.id }
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(
                title: L(direction == .input ? "section.input" : "section.output"),
                expanded: others.isEmpty ? nil : $expanded
            ) { EmptyView() }

            if let missing = audio.missingDevices[direction] {
                MissingDeviceNotice(direction: direction, missing: missing, standIn: selected)
            } else if let blocked = audio.blockedDevices[direction], let selected {
                BlockedSwitchNotice(direction: direction, blocked: blocked, chosen: selected)
            }
            if let selected {
                SelectedDeviceRow(device: selected, direction: direction, showsDetail: $showsDetail)
                if direction == .output, showsDetail {
                    DeviceProcessingPanel(device: selected)
                        .transition(.opacity)
                }
            } else {
                Text(L(direction == .input ? "device.input_not_found" : "device.output_not_found"))
                    .foregroundStyle(.secondary)
            }

            if expanded {
                ForEach(others) { device in
                    MenuRow {
                        audio.select(device, direction)
                    } label: {
                        HStack(spacing: 8) {
                            DeviceIcon(symbol: device.symbol)
                            Text(device.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .help(device.name)
                }
            }
        }
    }
}

private struct SelectedDeviceRow: View {
    @EnvironmentObject private var audio: AudioController
    let device: AudioDevice
    let direction: DeviceDirection
    @Binding var showsDetail: Bool

    var body: some View {
        let output = direction == .output
        let volume = output ? audio.outputVolume : audio.inputVolume
        let muted = output ? audio.outputMuted : audio.inputMuted
        let hasVolume = output ? audio.outputHasVolume : audio.inputHasVolume

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                DeviceIcon(symbol: device.symbol, selected: true)
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(device.name)
                Spacer(minLength: 4)
                Text(percent(volume)).percentStyle()
                if output {
                    IconToggle(symbol: "slider.vertical.3", help: L("device.processing"), isOn: $showsDetail)
                }
                IconButton(
                    symbol: output ? speakerSymbol(volume: volume, muted: muted) : muted ? "mic.slash.fill" : "mic.fill",
                    help: muted ? L("action.unmute") : L("action.mute"),
                    label: LF(muted ? "a11y.unmute" : "a11y.mute", device.name)
                ) {
                    audio.toggleMute(direction)
                }
                .disabled(audio.isDisabled(direction))
            }
            Slider(value: Binding(get: { volume }, set: { audio.setVolume($0, direction) }), in: 0...1) {
                Text(L(output ? "section.output" : "section.input"))
            }
            .labelsHidden()
            // Gray while muted; dragging still works and unmutes, like the system controls.
            .tint(muted ? Color.soundOff : nil)
            .disabled(!hasVolume || audio.isDisabled(direction))
            .help(percent(volume))
            .padding(.leading, Metrics.icon + 8)
        }
    }
}

private struct DeviceProcessingPanel: View {
    @EnvironmentObject private var audio: AudioController
    let device: AudioDevice

    var body: some View {
        let settings = audio.deviceSettings(for: device.uid)
        InsetGroup {
            Text(L("device.processing_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledRow(L("balance.help")) {
                BalanceSlider(value: settings.balance) { value in
                    audio.updateDeviceSettings(for: device) { $0.balance = value }
                }
            }
            Divider()
            EqualizerPanel(settings: settings.eq) { eq in
                audio.updateDeviceSettings(for: device) { $0.eq = eq }
            }
        }
    }
}

// MARK: - Multi-output

private struct MultiOutputSection: View {
    @EnvironmentObject private var audio: AudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.branch")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: Metrics.icon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("multi.global")).font(.headline)
                    Text(L("multi.global_subtitle")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(L("multi.global"), isOn: Binding(
                    get: { audio.state.globalMultiOutput },
                    set: { on in withAnimation(.snappy(duration: 0.2)) { audio.setGlobalMultiOutput(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if audio.state.globalMultiOutput {
                let others = audio.outputDevices.filter { $0.id != audio.outputDeviceID }
                if others.isEmpty {
                    Text(L("multi.no_other_devices"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Metrics.icon + 8)
                }
                ForEach(others) { device in
                    DeviceCheckRow(device: device, checked: audio.isGlobalOutput(device)) {
                        audio.toggleGlobalOutput(device)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @EnvironmentObject private var audio: AudioController
    @Binding var expanded: Bool
    @Binding var expandedApp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("tray.app_volume"), expanded: $expanded) {
                Toggle(L("tray.app_volume"), isOn: Binding(get: { audio.state.perAppEnabled }, set: { audio.setPerAppEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if expanded, audio.state.perAppEnabled {
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
                    ConflictNotice(names: audio.conflictingApps)
                }
                if audio.apps.isEmpty {
                    Text(L("tray.no_playing_apps"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(audio.apps) { app in
                    AppRow(app: app, expanded: Binding(
                        get: { expandedApp == app.id },
                        set: { expandedApp = $0 ? app.id : "" }
                    ))
                    if expandedApp == app.id {
                        AppSettingsPanel(app: app)
                            .transition(.opacity)
                    }
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
    @Binding var expanded: Bool

    var body: some View {
        let settings = audio.settings(for: app)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .accessibilityHidden(true)
                Text(app.name).lineLimit(1).help(app.name)
                if audio.appOutputMissing(app.id), let uid = settings.outputUID {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help(LF("guard.app_missing", audio.deviceName(uid: uid)))
                        .accessibilityLabel(LF("guard.app_missing", audio.deviceName(uid: uid)))
                } else if app.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                Text(percent(settings.volume)).percentStyle()
                IconButton(
                    symbol: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: settings.muted ? L("action.unmute") : L("action.mute"),
                    label: LF(settings.muted ? "a11y.unmute" : "a11y.mute", app.name)
                ) {
                    audio.updateSettings(for: app) { $0.muted.toggle() }
                }
                IconToggle(symbol: "slider.horizontal.3", help: L("app.settings"), label: LF("a11y.app_settings", app.name), isOn: $expanded)
            }
            // 0–200%; the tick in the middle is the app's own level.
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
            .padding(.leading, Metrics.icon + 8)
        }
        .contextMenu {
            Button(L("app.reset")) { audio.resetSettings(forApp: app.id) }
                .disabled(audio.state.apps[app.id] == nil)
        }
    }
}

private struct AppSettingsPanel: View {
    @EnvironmentObject private var audio: AudioController
    let app: AudioApp

    var body: some View {
        let settings = audio.settings(for: app)
        InsetGroup {
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
            }
            SwitchRow(L("app.multi_output"), isOn: settings.multiOutput) { on in
                audio.updateSettings(for: app) { $0.multiOutput = on }
            }
            if settings.multiOutput {
                let primary = settings.outputUID.flatMap { uid in audio.outputDevices.contains { $0.uid == uid } ? uid : nil } ?? audio.defaultOutput?.uid
                ForEach(audio.outputDevices.filter { $0.uid != primary }) { device in
                    DeviceCheckRow(device: device, checked: settings.extraOutputUIDs.contains(device.uid)) {
                        audio.updateSettings(for: app) { settings in
                            if let index = settings.extraOutputUIDs.firstIndex(of: device.uid) {
                                settings.extraOutputUIDs.remove(at: index)
                            } else {
                                settings.extraOutputUIDs.append(device.uid)
                            }
                        }
                    }
                }
            }
            SwitchRow(L("app.exclude_global"), isOn: settings.excludeFromGlobal) { on in
                audio.updateSettings(for: app) { $0.excludeFromGlobal = on }
            }
            LabeledRow(L("balance.help")) {
                BalanceSlider(value: settings.balance) { value in
                    audio.updateSettings(for: app) { $0.balance = value }
                }
            }
            Divider()
            EqualizerPanel(settings: settings.eq) { eq in
                audio.updateSettings(for: app) { $0.eq = eq }
            }
        }
    }
}

/// Expanded settings sit in an inset group; content, so a plain fill rather than glass.
private struct InsetGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .controlSize(.small)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.vertical, 2)
    }
}

/// A label on the left and its control on the right.
private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            content
        }
    }
}

/// A label on the left and a switch on the right.
private struct SwitchRow: View {
    let title: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    init(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.isOn = isOn
        self.onChange = onChange
    }

    var body: some View {
        LabeledRow(title) {
            Toggle(title, isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    var title: String?
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ConflictNotice: View {
    let names: [String]
    @Environment(\.locale) private var locale

    var body: some View {
        Notice(
            symbol: "exclamationmark.triangle.fill",
            tint: .orange,
            text: LF("conflict.warning", names.formatted(.list(type: .and).locale(locale)))
        ) { EmptyView() }
    }
}

/// Shown while the chosen device is missing: that direction is off, and nothing else is picked for it.
private struct MissingDeviceNotice: View {
    @EnvironmentObject private var audio: AudioController
    let direction: DeviceDirection
    let missing: MissingDevice
    let standIn: AudioDevice?

    var body: some View {
        Notice(
            symbol: "exclamationmark.triangle.fill",
            tint: .red,
            title: LF("guard.missing_title", missing.name),
            text: L(direction == .output ? "guard.output_disabled" : "guard.input_disabled")
        ) {
            if let standIn {
                Button(LF("guard.use_current", standIn.name)) { audio.useCurrentDevice(direction) }
            }
        }
    }
}

/// Shown after something else switched to another device (e.g. macOS when headphones connected) and
/// FreeAudio switched back to the chosen one.
private struct BlockedSwitchNotice: View {
    @EnvironmentObject private var audio: AudioController
    let direction: DeviceDirection
    let blocked: AudioDevice
    let chosen: AudioDevice

    var body: some View {
        Notice(symbol: "lock.fill", tint: .accentColor, text: LF("guard.blocked", blocked.name, chosen.name)) {
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
