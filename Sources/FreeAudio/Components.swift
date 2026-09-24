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

/// Section title with an optional trailing control and disclosure chevron.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var expanded: Binding<Bool>?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            accessory
            if let expanded {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(title)
                .accessibilityValue(expanded.wrappedValue ? L("action.collapse") : L("action.expand"))
            }
        }
        .frame(minHeight: 22)
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

/// A menu-style row that opens a submenu.
struct MenuRowMenu<Label: View, Content: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            content
        } label: {
            label.modifier(MenuItemLabel())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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

/// An icon button that shows its on state with a background, as the HIG asks of toggle buttons.
struct IconToggle: View {
    let symbol: String
    let help: String
    var label: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in withAnimation(.snappy(duration: 0.2)) { isOn = on } })) {
            Image(systemName: symbol)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(label ?? help)
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
        let size = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = state == .on ? "mic.fill" : "mic.slash.fill"
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "FreeAudio") else { return NSImage() }
        guard state != .on else {
            // Template images follow the menu bar: black on a light bar, white on a dark one.
            let image = base.withSymbolConfiguration(size) ?? base
            image.isTemplate = true
            return image
        }
        let image = base.withSymbolConfiguration(size.applying(.init(paletteColors: [.systemRed]))) ?? base
        image.isTemplate = false
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

/// Output device with a checkmark, for choosing extra outputs.
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
                if checked {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
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
                .fixedSize()
                Toggle(L("eq.title"), isOn: Binding(get: { settings.enabled }, set: { on in change { $0.enabled = on } }))
                    .toggleStyle(.switch)
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
