import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var language: LanguageSettings
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FreeAudio").font(.system(size: 20, weight: .bold))
                        Text(L("app.tagline")).foregroundStyle(.secondary)
                        Text(LF("settings.version", version))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker(selection: $language.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    Label(L("language.title"), systemImage: "globe")
                }
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    Label(L("settings.launch_at_login"), systemImage: "power")
                }
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { audio.state.remembersSound }, set: { audio.setRemembersSound($0) })) {
                    Label(L("settings.remember_sound"), systemImage: "arrow.counterclockwise.circle")
                }
            } header: {
                Text(L("settings.general"))
            } footer: {
                Text(L(audio.state.remembersSound && !launchAtLogin ? "settings.remember_sound_needs_login" : "settings.remember_sound_hint"))
                    .font(.caption)
                    .foregroundStyle(audio.state.remembersSound && !launchAtLogin ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("settings.devices")) {
                Toggle(isOn: Binding(get: { audio.state.locksDevices }, set: { audio.setLocksDevices($0) })) {
                    Label {
                        Text(L("settings.lock_devices"))
                        Text(L("settings.lock_devices_hint"))
                    } icon: {
                        Image(systemName: "lock")
                    }
                }
                Toggle(isOn: Binding(get: { audio.state.inputFollowsOutput }, set: { audio.setInputFollowsOutput($0) })) {
                    Label {
                        Text(L("settings.input_follows_output"))
                        Text(L("settings.input_follows_output_hint"))
                    } icon: {
                        Image(systemName: "headphones")
                    }
                }
                Toggle(isOn: Binding(get: { audio.state.newDevicesSilent }, set: { audio.setNewDevicesSilent($0) })) {
                    Label {
                        Text(L("settings.new_devices_silent"))
                        Text(L("settings.new_devices_silent_hint"))
                    } icon: {
                        Image(systemName: "speaker.slash")
                    }
                }
            }

            Section {
                LabeledContent {
                    StatusBadge(permission: audio.permission)
                } label: {
                    Label(L("settings.audio_capture"), systemImage: "waveform.badge.mic")
                }
                if let guidance = permissionGuidance {
                    Text(guidance).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if audio.permission == .notDetermined || audio.permission == .unknown {
                        Button(L("permission.request")) { audio.requestPermission() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(L("permission.open_settings")) { audio.openPrivacySettings() }
                    Spacer()
                    Button(L("action.rescan"), systemImage: "arrow.clockwise") { audio.rescan() }
                }
            } header: {
                Text(L("settings.permission"))
            } footer: {
                Text(L("settings.permission_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("settings.saved_apps")) {
                if savedApps.isEmpty {
                    Text(L("settings.no_saved_apps")).foregroundStyle(.secondary)
                } else {
                    ForEach(savedApps, id: \.self) { SavedAppRow(id: $0) }
                    Button(L("settings.reset_all_apps"), role: .destructive) { audio.resetAllAppSettings() }
                }
            }

            if !savedDevices.isEmpty {
                Section(L("settings.saved_devices")) {
                    ForEach(savedDevices, id: \.self) { uid in
                        LabeledContent {
                            Button(L("action.reset")) { audio.resetDeviceSettings(uid: uid) }
                        } label: {
                            Label(audio.deviceName(uid: uid), systemImage: symbol(forDevice: uid))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Rebuilds every string when the language changes.
        .id(language.language)
        .navigationTitle(L("window.settings_title"))
        .frame(width: 480)
        .frame(minHeight: 520)
        .onAppear(perform: refreshLoginState)
    }

    private var savedApps: [String] {
        audio.state.apps.keys.sorted {
            (audio.state.appNames[$0] ?? $0).localizedStandardCompare(audio.state.appNames[$1] ?? $1) == .orderedAscending
        }
    }

    private var savedDevices: [String] { audio.state.devices.keys.sorted() }

    private var permissionGuidance: String? {
        switch audio.permission {
        case .authorized: nil
        case .denied: L("permission.denied")
        case .notDetermined, .unknown: L("permission.request_hint")
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func symbol(forDevice uid: String) -> String {
        audio.outputDevices.first { $0.uid == uid }?.symbol ?? "hifispeaker"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = error.localizedDescription
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval { loginMessage = L("settings.login_needs_approval") }
    }
}

private struct StatusBadge: View {
    let permission: AudioCapturePermission.Status

    var body: some View {
        let (text, symbol, color): (String, String, Color) = switch permission {
        case .authorized: (L("permission.status_authorized"), "checkmark.circle.fill", .green)
        case .denied: (L("permission.status_denied"), "xmark.circle.fill", .red)
        case .notDetermined: (L("permission.status_not_determined"), "questionmark.circle.fill", .orange)
        case .unknown: (L("permission.status_unknown"), "exclamationmark.circle.fill", .orange)
        }
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct SavedAppRow: View {
    @EnvironmentObject private var audio: AudioController
    let id: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(audio.state.appNames[id] ?? id)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(L("action.reset")) { audio.resetSettings(forApp: id) }
        }
    }

    private var icon: NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var summary: String {
        let settings = audio.state.apps[id] ?? AppAudioSettings()
        var parts: [String] = []
        if settings.muted { parts.append(L("summary.muted")) }
        if settings.volume != 1 { parts.append(LF("summary.volume", percent(settings.volume))) }
        if let uid = settings.outputUID { parts.append(LF("summary.output", audio.deviceName(uid: uid))) }
        if settings.balance != 0 {
            let side = L(settings.balance < 0 ? "balance.left" : "balance.right")
            parts.append(LF("summary.balance", "\(side) \(percent(abs(settings.balance)))"))
        }
        if settings.eq.isActive { parts.append(LF("summary.eq", settings.eq.preset.title)) }
        if settings.multiOutput, !settings.extraOutputUIDs.isEmpty { parts.append(L("summary.multi")) }
        if settings.excludeFromGlobal { parts.append(L("summary.excluded")) }
        return parts.joined(separator: " · ")
    }
}
