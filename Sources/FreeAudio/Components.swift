import AppKit
import SwiftUI

enum Metrics {
    static let panelWidth: CGFloat = 360
    static let icon: CGFloat = 26
}

extension Color {
    /// Fill of a slider whose sound is off (muted or disabled).
    static let soundOff = Color(nsColor: .darkGray)
}

/// Controls that belong together, on a rounded background like a module in Control Center.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Round device icon, filled with the accent colour when selected, as in the system Sound menu.
struct DeviceIcon: View {
    let symbol: String
    var selected = false

    var body: some View {
        Image(systemName: symbol)
            .font(.callout)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Metrics.icon, height: Metrics.icon)
            .background(Circle().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary)))
            .accessibilityHidden(true)
    }
}

struct AppIcon: View {
    let app: AudioApp
    var size = Metrics.icon

    var body: some View {
        Image(nsImage: app.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The label of a menu item: full width, highlighted under the pointer, and clickable across the whole
/// highlighted area rather than only on its text.
private struct MenuItemLabel: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The panel hides without an exit event; don't come back highlighted.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hovering = false }
    }
}

/// A full-width menu-style row, like items in system menus.
struct MenuRow<Label: View>: View {
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label.modifier(MenuItemLabel())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .padding(.horizontal, -6)
    }
}

/// Small borderless icon button with a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    /// Spoken label; names the target when several rows have the same button.
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // A slashed speaker or microphone is red, like the menu bar icon.
        .foregroundStyle(symbol.contains(".slash") ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// The › at the end of a row that opens everything about it, as in System Settings.
struct DetailButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A label on the left and its control on the right.
struct LabeledRow<Content: View>: View {
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
        .frame(minHeight: 24)
    }
}

/// A label on the left and a switch on the right.
struct SwitchRow: View {
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
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Something that needs attention, tinted by how much.
struct Notice<Actions: View>: View {
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
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The menu bar icon: the microphone in the menu bar's color, or a red slashed microphone
/// while the chosen one is muted or there's none to use.
struct MenuBarIcon: View {
    let state: AudioController.MicrophoneState

    var body: some View {
        Image(nsImage: Self.image(state))
            .accessibilityLabel("FreeAudio")
            .accessibilityValue(L(state == .unavailable ? "mic.unavailable" : state == .muted ? "mic.muted" : "mic.on"))
    }

    static func image(_ state: AudioController.MicrophoneState) -> NSImage {
        var configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if state != .on { configuration = configuration.applying(.init(paletteColors: [.systemRed])) }
        guard let glyph = NSImage(systemSymbolName: state == .on ? "mic.fill" : "mic.slash.fill", accessibilityDescription: "FreeAudio")?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        // Drawn again onto an image of its own size. A symbol's image marks only its middle, about a capital letter's
        // height, as what to align, and the menu bar can lay it out by that alone, cutting off the top of the
        // microphone. A drawn image is aligned as a whole; both states are the same size, so nothing shifts.
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            return true
        }
        // Template images follow the menu bar: black on a light bar, white on a dark one.
        image.isTemplate = state == .on
        image.accessibilityDescription = "FreeAudio"
        return image
    }
}

/// Speaker glyph that follows the level.
func speakerSymbol(volume: Double, muted: Bool) -> String {
    if muted || volume <= 0.001 { return "speaker.slash.fill" }
    return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

extension Text {
    func percentStyle() -> some View {
        font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
    }
}

/// Release or pre-release, like the label GitHub puts on a release: green for a release, orange for a pre-release.
struct ReleaseBadge: View {
    let prerelease: Bool

    var body: some View {
        let color: Color = prerelease ? .orange : .green
        Text(L(prerelease ? "update.kind_prerelease" : "update.kind_release"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Output device with a round checkbox, for choosing extra outputs.
struct DeviceCheckRow: View {
    let device: AudioDevice
    let checked: Bool
    let action: () -> Void

    var body: some View {
        MenuRow(action: action) {
            HStack(spacing: 8) {
                DeviceIcon(symbol: device.symbol, selected: checked)
                Text(device.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                CheckMark(checked: checked)
            }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The round checkbox of an output that can play along with others, as in the AirPlay list.
struct CheckMark: View {
    let checked: Bool

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A checkbox button for an output that plays while multi-output is on.
struct CheckButton: View {
    let checked: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CheckMark(checked: checked).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// Left/right balance: a native slider filled from the centre.
struct BalanceSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        Slider(
            value: Binding(get: { value }, set: { onChange(abs($0) < 0.04 ? 0 : ($0 * 100).rounded() / 100) }),
            in: -1...1,
            neutralValue: 0
        ) {
            Text(L("balance.help"))
        } minimumValueLabel: {
            Text(L("balance.left"))
        } maximumValueLabel: {
            Text(L("balance.right"))
        } ticks: {
            SliderTick(0)
        }
        .labelsHidden()
        .help(L("balance.help"))
    }
}

/// Stereo, mono, or left and right swapped.
struct ChannelRow: View {
    let mode: ChannelMode
    let onChange: (ChannelMode) -> Void

    var body: some View {
        LabeledRow(L("channels.title")) {
            Picker(L("channels.title"), selection: Binding(get: { mode }, set: onChange)) {
                ForEach(ChannelMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

// MARK: - Summaries

extension DeviceAudioSettings {
    /// What FreeAudio does to the device's sound, in a few words; `nil` when nothing.
    var summary: String? {
        var parts: [String] = []
        if eq.isActive { parts.append(LF("summary.eq", eq.preset.title)) }
        if let correction, correction.enabled { parts.append(correction.name) }
        if leveling { parts.append(L("leveling.title")) }
        if channels != .stereo { parts.append(channels.title) }
        if balance != 0 { parts.append(balanceSummary(balance)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension AppAudioSettings {
    /// What FreeAudio does to the app's sound besides its volume and mute, in a few words; `nil` when nothing.
    func summary(deviceName: (String) -> String) -> String? {
        var parts: [String] = []
        if let uid = outputUID { parts.append(LF("summary.output", deviceName(uid))) }
        if multiOutput, !extraOutputUIDs.isEmpty { parts.append(L("summary.multi")) }
        if eq.isActive { parts.append(LF("summary.eq", eq.preset.title)) }
        if leveling { parts.append(L("leveling.title")) }
        if channels != .stereo { parts.append(channels.title) }
        if balance != 0 { parts.append(balanceSummary(balance)) }
        if excludeFromGlobal { parts.append(L("summary.excluded")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func balanceSummary(_ balance: Double) -> String {
    LF("summary.balance", "\(L(balance < 0 ? "balance.left" : "balance.right")) \(percent(abs(balance)))")
}

// MARK: - Equalizer

/// The Music app's equalizer: on/off, preset menu, preamp, a dB scale and ten band sliders.
struct EqualizerPanel: View {
    let settings: EQSettings
    let onChange: (EQSettings) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("eq.title"))
                Spacer(minLength: 8)
                Picker(L("eq.preset"), selection: Binding(get: { settings.preset }, set: { preset in change { $0.apply(preset) } })) {
                    // Like the Music app: "Manual" first, then the presets in alphabetical order.
                    if settings.preset == .custom {
                        Text(EQPreset.custom.title).tag(EQPreset.custom)
                        Divider()
                    }
                    ForEach(presets) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Toggle(L("eq.title"), isOn: Binding(get: { settings.enabled }, set: { on in change { $0.enabled = on } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            HStack(alignment: .top, spacing: 0) {
                band(title: L("eq.preamp"), value: settings.preamp) { value in change { $0.setPreamp(value) } }
                    .frame(width: 44)

                VStack(alignment: .trailing) {
                    Text("+12 dB")
                    Spacer()
                    Text("0 dB")
                    Spacer()
                    Text("−12 dB")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: EQSlider.height)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 4)

                ForEach(0..<Equalizer.bandCount, id: \.self) { index in
                    band(title: Equalizer.labels[index], value: settings.gains[index], unit: "Hz") { value in
                        change { $0.setGain(value, band: index) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .opacity(settings.enabled ? 1 : 0.5)

            HStack {
                Spacer()
                Button(L("action.reset")) { change { $0.apply(.flat) } }
                    .buttonStyle(.borderless)
                    .disabled(settings.preamp == 0 && settings.gains.allSatisfy { $0 == 0 })
            }
        }
    }

    private var presets: [EQPreset] {
        EQPreset.allCases.filter { $0 != .custom }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func band(title: String, value: Double, unit: String = "", onChange: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            EQSlider(value: value, label: unit.isEmpty ? title : "\(title) \(unit)", onChange: onChange)
                .frame(height: EQSlider.height)
            Text(title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func change(_ edit: (inout EQSettings) -> Void) {
        var next = settings
        edit(&next)
        onChange(next)
    }
}

/// A native vertical slider, filled from 0 dB (SwiftUI's `Slider` can't be vertical on macOS).
struct EQSlider: NSViewRepresentable {
    static let height: CGFloat = 108

    let value: Double
    let label: String
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: Equalizer.gainRange.lowerBound,
            maxValue: Equalizer.gainRange.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        slider.isVertical = true
        slider.isContinuous = true
        slider.neutralValue = 0
        // Eleven accent-filled tracks side by side would overpower the panel.
        slider.tintProminence = .secondary
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.toolTip = String(format: "%@  %+.1f dB", label, value)
        slider.setAccessibilityLabel(label)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }

        @objc func changed(_ sender: NSSlider) {
            // Tenth-of-a-decibel steps, with a detent at 0 dB.
            var value = (sender.doubleValue * 10).rounded() / 10
            if abs(value) < 0.4 { value = 0 }
            onChange(value)
        }
    }
}
