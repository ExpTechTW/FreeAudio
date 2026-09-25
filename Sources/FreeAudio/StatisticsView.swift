import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct StatisticsPage: View {
    @EnvironmentObject private var usage: UsageStats
    @EnvironmentObject private var audio: AudioController
    @Environment(\.locale) private var locale
    @State private var selected: Date
    @State private var confirmingReset = false

    init(day: Date = Date()) {
        _selected = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        let day = usage.day(selected)
        let hours = usage.hours(selected)
        // Time something played or recorded, however many devices at once.
        let playing = hours.filter { $0.direction == .output }.reduce(0) { $0 + $1.minutes } * 60
        let recording = hours.filter { $0.direction == .input }.reduce(0) { $0 + $1.minutes } * 60
        let output = day.total(.output)
        Form {
            PageHeader(page: .statistics)

            Section {
                WeekStrip(selected: $selected, value: { usage.day($0).total(.output).seconds }, caption: { shortDuration(usage.day($0).total(.output).seconds) })
                Headline(
                    value: playing > 0 ? durationText(playing) : L("stats.silent_day"),
                    title: LF("stats.played_on", dayName(selected)),
                    facts: [
                        recording > 0 ? LF("stats.fact_recorded", durationText(recording)) : nil,
                        output.averageVolume.map { LF("stats.fact_volume", percent($0)) },
                        output.mutedSeconds >= 60 ? LF("stats.fact_muted", durationText(output.mutedSeconds)) : nil,
                    ].compactMap { $0 }
                )
                .padding(.vertical, 4)
            }

            Section(L("stats.rhythm")) {
                HeatStrip(hours: hours)
                Timeline(lanes: usage.lanes(selected))
            }

            Section(L("stats.where")) {
                HStack(alignment: .top, spacing: 20) {
                    SourceList(title: L("stats.devices"), items: devices(day))
                    SourceList(title: L("stats.apps"), items: apps(day))
                }
                .padding(.vertical, 4)
            }

            Section(L("stats.records")) {
                Toggle(isOn: Binding(get: { usage.settings.tracking }, set: { usage.setTracking($0) })) {
                    Text(L("stats.tracking"))
                    Text(L("stats.tracking_hint"))
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Menu(L("stats.export")) {
                            Button(L("stats.export_week")) { export(usage.csv(week: selected), name: "FreeAudio Statistics (minutes).csv") }
                            Button(L("stats.export_all")) { export(usage.csv(), name: "FreeAudio Statistics.csv") }
                        }
                        .fixedSize()
                        Button(L("stats.reset"), role: .destructive) { confirmingReset = true }
                    }
                } label: {
                    Text(L("stats.storage"))
                    Text(usage.storedBytes.map { LF("stats.storage_detail", ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) } ?? " ")
                }
            }
        }
        .confirmationDialog(L("stats.reset_confirm"), isPresented: $confirmingReset) {
            Button(L("stats.reset_action"), role: .destructive) { usage.reset() }
        }
    }

    private func dayName(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? L("stats.today") : date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
    }

    private func devices(_ day: UsageDay) -> [SourceList.Item] {
        let outputs = day.records(.output).map { (DeviceDirection.output, $0.uid, $0.record) }
        let inputs = day.records(.input).map { (DeviceDirection.input, $0.uid, $0.record) }
        return (outputs + inputs).sorted { $0.2.seconds > $1.2.seconds }.map { direction, uid, record in
            let current = (direction == .output ? audio.outputDevices : audio.inputDevices).first { $0.uid == uid }
            var detail = [L(direction == .output ? "stats.output" : "stats.input")]
            if let average = record.averageVolume { detail.append(LF("stats.fact_volume", percent(average))) }
            if record.mutedSeconds >= 60 { detail.append(LF("stats.fact_muted", durationText(record.mutedSeconds))) }
            return SourceList.Item(
                id: "\(direction.key):\(uid)", name: record.name, icon: .symbol(current?.symbol ?? (direction == .output ? "hifispeaker" : "mic")),
                seconds: record.seconds, detail: detail.joined(separator: " · "), tint: direction == .output ? .blue : .purple
            )
        }
    }

    private func apps(_ day: UsageDay) -> [SourceList.Item] {
        day.apps.map { key, record in
            let playing = key.kind == .playingApp
            let devices = record.devices.sorted { $0.value > $1.value }.map { day.records[$0.key]?.name ?? audio.deviceName(uid: $0.key.key) }
            return SourceList.Item(
                id: "\(key.kind.rawValue):\(key.key)", name: record.name, icon: .app(key.key), seconds: record.seconds,
                detail: ([L(playing ? "stats.app_playing" : "stats.app_recording")] + devices.prefix(2)).joined(separator: " · "),
                tint: playing ? .blue : .purple
            )
        }
    }
}

/// Each hour of the day as a cell, darker the more of it something played (or recorded); pointing at an hour shows its
/// minutes.
private struct HeatStrip: View {
    let hours: [UsageStats.Hour]
    @State private var pointed: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("stats.by_hour")).font(.callout.weight(.medium))
                Spacer()
                if let pointed {
                    Text(LF("stats.hour_readout", String(format: "%02d:00", pointed), durationText(minutes(pointed, .output) * 60), durationText(minutes(pointed, .input) * 60)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach([DeviceDirection.output, .input], id: \.key) { direction in
                HStack(spacing: 8) {
                    Text(L(direction == .output ? "stats.app_playing" : "stats.app_recording"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    HStack(spacing: 2) {
                        ForEach(0..<24, id: \.self) { hour in
                            let share = minutes(hour, direction) / 60
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill((direction == .output ? Color.blue : .purple).opacity(share > 0 ? 0.18 + 0.82 * share : 0.06))
                                .frame(height: 16)
                                .overlay {
                                    if pointed == hour { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.primary.opacity(0.5), lineWidth: 1) }
                                }
                                .onHover { inside in
                                    if inside { pointed = hour } else if pointed == hour { pointed = nil }
                                }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 44, height: 1)
                HStack(spacing: 0) {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(String(format: "%02d", hour)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("stats.by_hour"))
    }

    private func minutes(_ hour: Int, _ direction: DeviceDirection) -> Double {
        hours.first { $0.hour == hour && $0.direction == direction }?.minutes ?? 0
    }
}

private struct Timeline: View {
    let lanes: [UsageStats.Lane]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("stats.timeline")).font(.callout.weight(.medium))
            if lanes.isEmpty {
                Text(L("stats.no_usage")).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(lanes) { lane in
                        let output = lane.source.kind == .output || lane.source.kind == .playingApp
                        ForEach(lane.runs, id: \.lowerBound) { run in
                            RectangleMark(
                                xStart: .value("from", Double(run.lowerBound) / 60), xEnd: .value("to", Double(run.upperBound) / 60),
                                y: .value("source", lane.name), height: 10
                            )
                            .foregroundStyle(by: .value("direction", L(output ? "stats.output" : "stats.input")))
                            .cornerRadius(2)
                        }
                    }
                }
                .chartForegroundStyleScale([L("stats.output"): Color.blue, L("stats.input"): Color.purple])
                .chartXScale(domain: 0...24)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(String(format: "%02d:00", Int(value.as(Double.self) ?? 0))) }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel { Text(value.as(String.self) ?? "").lineLimit(1) }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(lanes.count) * 24 + 24)
                Text(L("stats.timeline_hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}


/// Where the day's time went: one kind of source, most used first, each with a bar for its share.
private struct SourceList: View {
    struct Item: Identifiable {
        enum Icon {
            case symbol(String)
            /// An app's icon, by bundle identifier.
            case app(String)
        }

        let id: String
        let name: String
        let icon: Icon
        let seconds: Double
        let detail: String
        let tint: Color
    }

    let title: String
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(L("stats.nothing")).foregroundStyle(.secondary)
            }
            let longest = items.map(\.seconds).max() ?? 1
            ForEach(items.prefix(8)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        switch item.icon {
                        case .symbol(let symbol):
                            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                        case .app(let id):
                            Image(nsImage: Self.icon(id)).resizable().frame(width: 18, height: 18)
                        }
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(durationText(item.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Meter(fraction: item.seconds / max(longest, 1), tint: item.tint)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Apps that aren't installed any more get the generic icon.
    static func icon(_ bundleIdentifier: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// A duration on a chart's axis, where the bottom is just 0.
func axisDuration(_ seconds: Double) -> String { seconds > 0 ? durationText(seconds) : "0" }

/// Saves `text` where the user picks.
@MainActor
func export(_ text: String, name: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = name
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
