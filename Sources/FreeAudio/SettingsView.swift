import ServiceManagement
import SwiftUI

struct GeneralPage: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var language: LanguageSettings
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    var body: some View {
        let needsLogin = audio.state.remembersSound && !launchAtLogin
        Form {
            PageHeader(page: .general)

            Section(L("settings.startup")) {
                // A closure rather than the method itself: the Swift 6.3 compiler in Xcode 26.6 crashes turning
                // a method into the setter SwiftUI takes.
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    Text(L("settings.launch_at_login"))
                    Text(loginMessage ?? L("settings.launch_at_login_hint"))
                        .foregroundStyle(loginMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                Toggle(isOn: Binding(get: { audio.state.remembersSound }, set: { audio.setRemembersSound($0) })) {
                    Text(L("settings.remember_sound"))
                    Text(L(needsLogin ? "settings.remember_sound_needs_login" : "settings.remember_sound_hint"))
                        .foregroundStyle(needsLogin ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }

            Section {
                Picker(L("language.title"), selection: $language.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section(L("settings.permission")) {
                LabeledContent {
                    StatusBadge(permission: audio.permission)
                } label: {
                    Text(L("settings.audio_capture"))
                    Text(L("settings.permission_hint"))
                }
                if let guidance = permissionGuidance {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(guidance).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if audio.permission == .notDetermined || audio.permission == .unknown {
                                Button(L("permission.request")) { audio.requestPermission() }
                                    .buttonStyle(.borderedProminent)
                            }
                            Button(L("permission.open_settings")) { audio.openPrivacySettings() }
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    Button(L("action.rescan")) { audio.rescan() }
                } label: {
                    Text(L("settings.rescan"))
                    Text(L("settings.rescan_hint"))
                }
            }
        }
        .onAppear(perform: refreshLoginState)
    }

    private var permissionGuidance: String? {
        switch audio.permission {
        case .authorized: nil
        case .denied: L("permission.denied")
        case .notDetermined, .unknown: L("permission.request_hint")
        }
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

struct DevicesPage: View {
    @EnvironmentObject private var audio: AudioController

    var body: some View {
        Form {
            PageHeader(page: .devices)

            Section(L("settings.switching")) {
                Toggle(isOn: Binding(get: { audio.state.locksDevices }, set: { audio.setLocksDevices($0) })) {
                    Text(L("settings.lock_devices"))
                    Text(L("settings.lock_devices_hint"))
                }
                Toggle(isOn: Binding(get: { audio.state.inputFollowsOutput }, set: { audio.setInputFollowsOutput($0) })) {
                    Text(L("settings.input_follows_output"))
                    Text(L("settings.input_follows_output_hint"))
                }
            }

            Section(L("settings.new_devices")) {
                Toggle(isOn: Binding(get: { audio.state.newDevicesSilent }, set: { audio.setNewDevicesSilent($0) })) {
                    Text(L("settings.new_devices_silent"))
                    Text(L("settings.new_devices_silent_hint"))
                }
            }

            Section {
                if savedDevices.isEmpty {
                    Text(L("settings.no_saved_devices")).foregroundStyle(.secondary)
                }
                ForEach(savedDevices, id: \.self) { uid in
                    LabeledContent {
                        Button(L("action.reset")) { audio.resetDeviceSettings(uid: uid) }
                    } label: {
                        Label {
                            Text(audio.deviceName(uid: uid))
                            Text(summary(uid))
                        } icon: {
                            Image(systemName: audio.outputDevices.first { $0.uid == uid }?.symbol ?? "hifispeaker")
                        }
                    }
                }
            } header: {
                Text(L("settings.saved_devices"))
            } footer: {
                Text(L("settings.saved_devices_hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var savedDevices: [String] {
        audio.state.devices.keys.sorted { audio.deviceName(uid: $0).localizedStandardCompare(audio.deviceName(uid: $1)) == .orderedAscending }
    }

    private func summary(_ uid: String) -> String {
        let settings = audio.deviceSettings(for: uid)
        let level = [settings.muted ? L("summary.muted") : nil, settings.volume != 1 ? LF("summary.volume", percent(settings.volume)) : nil]
        return (level.compactMap { $0 } + [settings.summary].compactMap { $0 }).joined(separator: " · ")
    }
}

struct AppsPage: View {
    @EnvironmentObject private var audio: AudioController

    var body: some View {
        Form {
            PageHeader(page: .apps)

            Section {
                Toggle(isOn: Binding(get: { audio.state.perAppEnabled }, set: { audio.setPerAppEnabled($0) })) {
                    Text(L("settings.per_app"))
                    Text(L("settings.per_app_hint"))
                }
            }

            Section {
                if savedApps.isEmpty {
                    Text(L("settings.no_saved_apps")).foregroundStyle(.secondary)
                }
                ForEach(savedApps, id: \.self) { SavedAppRow(id: $0) }
            } header: {
                Text(L("settings.saved_apps"))
            } footer: {
                Text(L("settings.saved_apps_hint")).font(.caption).foregroundStyle(.secondary)
            }

            if !savedApps.isEmpty {
                Section {
                    Button(L("settings.reset_all_apps"), role: .destructive) { audio.resetAllAppSettings() }
                }
            }
        }
    }

    private var savedApps: [String] {
        audio.state.apps.keys.sorted {
            (audio.state.appNames[$0] ?? $0).localizedStandardCompare(audio.state.appNames[$1] ?? $1) == .orderedAscending
        }
    }
}

/// An app whose settings FreeAudio remembers, whether it's open or not.
private struct SavedAppRow: View {
    @EnvironmentObject private var audio: AudioController
    let id: String

    var body: some View {
        LabeledContent {
            Button(L("action.reset")) { audio.resetSettings(forApp: id) }
        } label: {
            Label {
                Text(audio.state.appNames[id] ?? id)
                Text(summary)
            } icon: {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
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
        let level = [settings.muted ? L("summary.muted") : nil, settings.volume != 1 ? LF("summary.volume", percent(settings.volume)) : nil]
        return (level.compactMap { $0 } + [settings.summary(deviceName: audio.deviceName(uid:))].compactMap { $0 }).joined(separator: " · ")
    }
}


struct UpdatesPage: View {
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var language: LanguageSettings

    var body: some View {
        Form {
            PageHeader(page: .updates)

            Section {
                LabeledContent(L("update.current")) {
                    HStack(spacing: 8) {
                        Text(updater.build.label).monospacedDigit().textSelection(.enabled)
                        ReleaseBadge(prerelease: updater.build.isPrerelease)
                    }
                }
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 8)
                    if updater.available != nil, !updater.isBusy {
                        Button(L("update.view_changes")) { updater.openReleasePage() }
                        Button(L("update.install")) { updater.install() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(L("update.check_now")) { updater.check() }
                            .disabled(updater.isBusy || updater.unavailableReason != nil)
                    }
                }
            } footer: {
                if let last = updater.preferences.lastCheck, updater.unavailableReason == nil {
                    Text(LF("update.last_checked", last.formatted(.dateTime.month().day().hour().minute().locale(language.language.locale))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if updater.unavailableReason == nil {
                Section {
                    Toggle(isOn: Binding(get: { updater.preferences.checksAutomatically }, set: { updater.setChecksAutomatically($0) })) {
                        Text(L("update.automatic"))
                        Text(L("update.automatic_hint"))
                    }
                    Toggle(isOn: Binding(get: { updater.channel == .prerelease }, set: { updater.setReceivesPrereleases($0) })) {
                        Text(L("update.prerelease"))
                        Text(L("update.prerelease_hint"))
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let reason = updater.unavailableReason {
            Text(reason).foregroundStyle(.secondary)
        } else {
            switch updater.phase {
            case .idle:
                if let release = updater.available { Text(LF("update.available", release.label)) }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("update.checking")).foregroundStyle(.secondary)
                }
            case .upToDate:
                Label(L("update.up_to_date"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .downloading(let percent):
                VStack(alignment: .leading, spacing: 4) {
                    Text(LF("update.downloading", "\(percent)%")).foregroundStyle(.secondary)
                    ProgressView(value: Double(percent), total: 100)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("update.installing")).foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Text(failure.message)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AboutPage: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FreeAudio").font(.title.bold())
                        Text(L("app.tagline")).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(LF("settings.version", updater.build.label)).monospacedDigit().textSelection(.enabled)
                            ReleaseBadge(prerelease: updater.build.isPrerelease)
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }

            Section(L("about.links")) {
                link(L("about.github"), symbol: "chevron.left.forwardslash.chevron.right", path: "")
                link(L("about.changelog"), symbol: "doc.text", path: "/releases")
                link(L("about.issues"), symbol: "exclamationmark.bubble", path: "/issues")
            }

            Section(L("about.license")) {
                Text(L("about.license_summary")).fixedSize(horizontal: false, vertical: true)
                link(L("about.read_license"), symbol: "doc.plaintext", path: "/blob/main/LICENSE")
            }
        }
    }

    private func link(_ title: String, symbol: String, path: String) -> some View {
        let repository = updater.build.repository ?? "ExpTechTW/FreeAudio"
        return Link(destination: URL(string: "https://github.com/\(repository)\(path)")!) {
            LabeledContent {
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            } label: {
                Label(title, systemImage: symbol)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
