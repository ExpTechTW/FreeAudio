import SwiftUI

/// Everything about one app's sound: its volume, where it plays, its sound and its equalizer. The menu bar panel
/// shows it on an app's page, and Settings for every app, hidden ones too.
struct AppEditor: View {
    @EnvironmentObject private var audio: AudioController
    let app: AudioApp

    var body: some View {
        let settings = audio.settings(for: app)
        // Where the app plays: its own device if that's connected, otherwise the system's.
        let primary = settings.outputUID.flatMap { uid in audio.outputDevices.contains { $0.uid == uid } ? uid : nil } ?? audio.defaultOutput?.uid
        let others = audio.outputDevices.filter { $0.uid != primary }
        VStack(alignment: .leading, spacing: 10) {
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
                if let silent = audio.silentOutput(forApp: app.id) {
                    SilentOutputNotice(device: silent)
                }
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
                ChannelRow(mode: settings.channels) { mode in audio.updateSettings(for: app) { $0.channels = mode } }
                SwitchRow(L("leveling.title"), isOn: settings.leveling) { on in audio.updateSettings(for: app) { $0.leveling = on } }
                    .help(L("leveling.help"))
            }

            Card {
                EqualizerPanel(settings: settings.eq) { eq in audio.updateSettings(for: app) { $0.eq = eq } }
            }

            Card {
                SwitchRow(L("app.hide"), isOn: audio.isHidden(app.id)) { on in audio.setHidden(on, app: app.id, name: app.name) }
                Text(L("app.hide_hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Button(L("app.reset"), role: .destructive) { audio.resetSettings(forApp: app.id) }
                .buttonStyle(.borderless)
                .disabled(audio.state.apps[app.id] == nil)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The device an app is sent to is muted or at zero, so the app can't be heard; with a way to turn it back up.
struct SilentOutputNotice: View {
    @EnvironmentObject private var audio: AudioController
    let device: AudioDevice

    var body: some View {
        let level = audio.level(of: device, .output)
        Notice(symbol: "speaker.slash.fill", tint: .orange, text: LF(level.muted ? "app.output_muted" : "app.output_silent", device.name)) {
            if level.muted {
                Button(L("action.unmute")) { audio.toggleMute(device, .output) }
            }
        }
    }
}

/// 0–200%; the tick in the middle is the app's own level.
struct AppVolumeSlider: View {
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
