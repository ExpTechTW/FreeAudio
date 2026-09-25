import Charts
import SwiftUI

struct HearingPage: View {
    @EnvironmentObject private var hearing: HearingMonitor
    @EnvironmentObject private var audio: AudioController
    @Environment(\.locale) private var locale
    @State private var selected: Date
    @State private var confirmingReset = false
    @State private var showsCalibration = false

    init(day: Date = Date()) {
        _selected = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        let settings = hearing.settings
        let tally = hearing.day(selected)
        Form {
            PageHeader(page: .hearing)

            Section {
                Toggle(isOn: Binding(get: { settings.monitoring }, set: { on in hearing.update { $0.monitoring = on } })) {
                    Text(L("hearing.estimate"))
                    Text(L("hearing.estimate_hint"))
                }
                if settings.monitoring {
                    TodayOverview(dose: hearing.day(Date()).dose, live: hearing.live, lastMinute: hearing.lastMinute, threshold: settings.threshold)
                        .padding(.vertical, 6)
                }
            }

            Section(L("hearing.by_day")) {
                WeekStrip(
                    selected: $selected,
                    value: { hearing.day($0).dose },
                    caption: { date in
                        let day = hearing.day(date)
                        return day.monitored > 0 ? "\(Int(day.dose.rounded()))%" : "—"
                    },
                    tint: { Exposure.doseColor(hearing.day($0).dose) }
                )
                if tally.monitored == 0 {
                    Text(L("hearing.no_listening")).foregroundStyle(.secondary)
                } else {
                    Headline(
                        value: "\(Int(tally.dose.rounded()))%",
                        title: LF("hearing.dose_on", dayName(selected)),
                        facts: [
                            LF("hearing.fact_listened", durationText(tally.monitored)),
                            tally.average.map { LF("hearing.fact_average", Int($0.rounded())) },
                            LF("hearing.fact_loudest", Int(tally.peak.rounded())),
                            tally.seconds(from: settings.threshold) >= 1 ? LF("hearing.fact_above", settings.threshold, durationText(tally.seconds(from: settings.threshold))) : nil,
                        ].compactMap { $0 }
                    )
                    LevelCurve(minutes: hearing.minutes(selected), threshold: settings.threshold)
                    Distribution(levels: tally.levels, threshold: settings.threshold)
                }
            }

            Section(L("hearing.this_week")) {
                let week = Day.lastSeven(until: Date()).map { hearing.day($0) }
                let allowance = Exposure.weeklyDose(energy: week.reduce(0) { $0 + $1.energy })
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LF("hearing.allowance_used", Int(allowance.rounded())))
                        Spacer()
                        Text(LF("hearing.fact_listened", durationText(week.reduce(0) { $0 + $1.monitored })))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Meter(fraction: allowance / 100, tint: Exposure.doseColor(allowance))
                    Text(L("hearing.allowance_hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(L("hearing.reminders")) {
                Toggle(isOn: Binding(get: { settings.alerts }, set: { on in hearing.update { $0.alerts = on } })) {
                    Text(L("hearing.remind"))
                    Text(L("hearing.remind_hint"))
                }
                if settings.alerts {
                    LabeledContent(L("hearing.remind_when")) {
                        HStack(spacing: 6) {
                            Picker(L("hearing.remind_level"), selection: Binding(get: { settings.threshold }, set: { level in hearing.update { $0.threshold = level } })) {
                                ForEach(Exposure.thresholds, id: \.self) { Text(LF("hearing.over_level", $0)).tag($0) }
                            }
                            Picker(L("hearing.remind_duration"), selection: Binding(get: { settings.alertDelay }, set: { delay in hearing.update { $0.alertDelay = delay } })) {
                                ForEach(Exposure.alertDelays, id: \.self) { Text(LF("hearing.for_duration", durationText($0))).tag($0) }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Toggle(isOn: Binding(get: { settings.weeklySummary }, set: { on in hearing.update { $0.weeklySummary = on } })) {
                    Text(L("hearing.weekly"))
                    Text(L("hearing.weekly_hint"))
                }
                if settings.weeklySummary {
                    LabeledContent(L("hearing.weekly_when")) {
                        HStack(spacing: 6) {
                            Picker(L("hearing.weekly_when"), selection: Binding(get: { settings.summaryWeekday }, set: { day in hearing.update { $0.summaryWeekday = day } })) {
                                ForEach(1...7, id: \.self) { Text(weekdayName($0)).tag($0) }
                            }
                            Picker(L("hearing.weekly_when"), selection: Binding(get: { settings.summaryHour }, set: { hour in hearing.update { $0.summaryHour = hour } })) {
                                ForEach(0..<24, id: \.self) { Text(hourName($0)).tag($0) }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsCalibration) {
                    Text(L("hearing.calibrate_hint")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(calibrated, id: \.uid) { device in
                        let value = hearing.calibration(for: device.uid)
                        LabeledContent {
                            Stepper(value: Binding(get: { value }, set: { new in hearing.update { $0.calibration[device.uid] = new } }), in: Exposure.calibrationRange, step: 0.5) {
                                Text(String(format: "%+.1f dB", value)).monospacedDigit()
                            }
                        } label: {
                            Label {
                                Text(device.name)
                                Text(device.detail)
                            } icon: {
                                Image(systemName: device.symbol)
                            }
                        }
                    }
                } label: {
                    LabeledContent {
                        let count = hearing.settings.calibration.count
                        Text(count > 0 ? LF("hearing.calibrated_count", count) : L("hearing.not_calibrated")).foregroundStyle(.secondary)
                    } label: {
                        Text(L("hearing.calibrate"))
                    }
                }
            }

            Section {
                HStack {
                    Menu(L("stats.export")) {
                        Button(L("hearing.export_week")) { export(hearing.csv(week: Date()), name: "FreeAudio Hearing (minutes).csv") }
                        Button(L("stats.export_all")) { export(hearing.csv(), name: "FreeAudio Hearing.csv") }
                    }
                    .fixedSize()
                    Spacer()
                    Button(L("hearing.reset"), role: .destructive) { confirmingReset = true }
                }
            }
        }
        .confirmationDialog(L("hearing.reset_confirm"), isPresented: $confirmingReset) {
            Button(L("hearing.reset_action"), role: .destructive) { hearing.reset() }
        }
    }

    /// Connected outputs, and any other calibrated one.
    private var calibrated: [(uid: String, name: String, detail: String, symbol: String)] {
        let connected = audio.outputDevices.map { device in
            (device.uid, device.name, LF("hearing.reference", kindName(device.kind), Int(Exposure.reference(for: device.kind))), device.symbol)
        }
        let others = hearing.settings.calibration.keys.filter { uid in !connected.contains { $0.0 == uid } }.sorted()
            .map { ($0, audio.deviceName(uid: $0), L("device.not_connected"), "hifispeaker") }
        return (connected + others).map { (uid: $0.0, name: $0.1, detail: $0.2, symbol: $0.3) }
    }

    private func dayName(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? L("stats.today") : date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
    }

    private func kindName(_ kind: AudioDevice.Kind) -> String {
        switch kind {
        case .headphones: L("hearing.kind_headphones")
        case .builtInSpeakers: L("hearing.kind_builtin")
        case .speakers: L("hearing.kind_speakers")
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar.weekdaySymbols[weekday - 1]
    }

    private func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }
}

extension Exposure {
    /// Green while well within the day's (or week's) share, orange as it nears it, red past it.
    static func doseColor(_ percent: Double) -> Color {
        percent < 50 ? .green : percent < 100 ? .orange : .red
    }

    static func doseStatus(_ percent: Double) -> String {
        L(percent < 50 ? "hearing.dose_low" : percent < 100 ? "hearing.dose_near" : "hearing.dose_over")
    }
}

/// Today's dose as a ring, and beside it what's heard now with the last minute's trend.
private struct TodayOverview: View {
    let dose: Double
    let live: HearingMonitor.Live?
    let lastMinute: [Double?]
    let threshold: Int

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            DoseRing(dose: dose)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("hearing.now")).font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(live?.level.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("dB").foregroundStyle(.secondary)
                    if let level = live?.level {
                        Text(Self.feel(level)).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 6)
                    }
                }
                .animation(.snappy, value: live?.level.map { Int($0.rounded()) })
                Sparkline(levels: lastMinute, threshold: threshold)
                    .frame(height: 34)
                if let live {
                    Text("\(live.device) · \(percent(live.volume))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(L("hearing.nothing_now")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func feel(_ level: Double) -> String {
        L(level < 70 ? "hearing.feel_soft" : level < 80 ? "hearing.feel_moderate" : level < 90 ? "hearing.feel_loud" : "hearing.feel_very_loud")
    }
}

/// How much of today's safe listening is used, as a ring that fills up.
private struct DoseRing: View {
    let dose: Double

    var body: some View {
        let color = Exposure.doseColor(dose)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 11)
            Circle()
                .trim(from: 0, to: min(dose / 100, 1))
                .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(Int(dose.rounded()))%").font(.title2.weight(.semibold)).monospacedDigit()
                Text(L("hearing.dose_today")).font(.caption2).foregroundStyle(.secondary)
                Text(Exposure.doseStatus(dose)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("hearing.dose_today"))
        .accessibilityValue("\(Int(dose.rounded()))%, \(Exposure.doseStatus(dose))")
    }
}

/// The last minute's levels as a line, with the reminder's threshold.
private struct Sparkline: View {
    let levels: [Double?]
    let threshold: Int

    var body: some View {
        let points = levels.enumerated().compactMap { index, level in level.map { (index, $0) } }
        let stretches = runs(points.map(\.0))
        Chart {
            RuleMark(y: .value("threshold", threshold)).foregroundStyle(.orange.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(Array(stretches.enumerated()), id: \.offset) { index, stretch in
                ForEach(points.filter { stretch.contains($0.0) }, id: \.0) { second, level in
                    LineMark(x: .value("second", second), y: .value("level", level), series: .value("stretch", index))
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: 0...59)
        .chartYScale(domain: 40...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

/// How the day's listening time spreads over levels, a bar per dB, with the reminder's threshold; pointing at a bar
/// shows its time.
private struct Distribution: View {
    let levels: [Int: Double]
    let threshold: Int
    @State private var pointed: Int?

    var body: some View {
        let low = min(levels.keys.min() ?? 50, 50), high = max(levels.keys.max() ?? 90, threshold + 5)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("hearing.distribution")).font(.callout.weight(.medium))
                Spacer()
                if let pointed {
                    Text(LF("hearing.distribution_readout", pointed, durationText(levels[pointed] ?? 0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(levels.sorted { $0.key < $1.key }, id: \.key) { level, seconds in
                    RectangleMark(
                        xStart: .value("from", Double(level) + 0.1), xEnd: .value("to", Double(level) + 0.9),
                        yStart: .value("none", 0.0), yEnd: .value("minutes", seconds / 60)
                    )
                    .foregroundStyle(level >= threshold ? Color.orange : Color.pink.opacity(0.75))
                    .cornerRadius(1.5)
                }
                RuleMark(x: .value("threshold", threshold)).foregroundStyle(.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXScale(domain: Double(low)...Double(high + 1))
            .chartXAxis {
                AxisMarks(values: .stride(by: 10)) { value in
                    AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0)) dB") }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(axisDuration((value.as(Double.self) ?? 0) * 60)) }
                }
            }
            .chartXSelection(value: Binding(get: { pointed.map(Double.init) }, set: { pointed = $0.map { Int($0.rounded(.down)) } }))
            .frame(height: 120)
            Text(LF("hearing.distribution_hint", threshold)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LevelCurve: View {
    let minutes: [(minute: Int, level: Double, peak: Double)]
    let threshold: Int
    @State private var pointed: Double?

    var body: some View {
        // Spans in a row make one line; a gap in listening breaks it.
        let stretches = runs(minutes.map { $0.minute / 5 }).map { $0.lowerBound * 5..<$0.upperBound * 5 }
        let low = min((minutes.map(\.level).min() ?? 50) - 5, 50), high = max((minutes.map(\.peak).max() ?? 90) + 3, Double(threshold) + 5)
        let shown = pointed.flatMap { hour in minutes.min { abs(Double($0.minute) / 60 - hour) < abs(Double($1.minute) / 60 - hour) } }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                if let shown {
                    let end = shown.minute + 5
                    Text(LF("hearing.minute_readout", String(format: "%02d:%02d–%02d:%02d", shown.minute / 60, shown.minute % 60, end / 60 % 24, end % 60),
                            Int(shown.level.rounded()), Int(shown.peak.rounded())))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(" ").font(.caption)
                }
            }
            Chart {
                RuleMark(y: .value("threshold", threshold))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(LF("hearing.threshold_line", threshold)).font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(Array(stretches.enumerated()), id: \.offset) { index, stretch in
                    ForEach(minutes.filter { stretch.contains($0.minute) }, id: \.minute) { minute in
                        LineMark(x: .value("time", Double(minute.minute) / 60), y: .value("level", minute.level), series: .value("stretch", index))
                            .foregroundStyle(.pink)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        if stretch.count == 1 {
                            PointMark(x: .value("time", Double(minute.minute) / 60), y: .value("level", minute.level))
                                .foregroundStyle(.pink)
                                .symbolSize(20)
                        }
                    }
                }
                if let shown {
                    RuleMark(x: .value("time", Double(shown.minute) / 60)).foregroundStyle(.secondary.opacity(0.4))
                    PointMark(x: .value("time", Double(shown.minute) / 60), y: .value("level", shown.level))
                        .foregroundStyle(.pink)
                        .symbolSize(50)
                }
            }
            .chartXScale(domain: 0...24)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(String(format: "%02d:00", Int(value.as(Double.self) ?? 0))) }
                }
            }
            .chartYScale(domain: low...high)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0) dB") }
                }
            }
            .chartXSelection(value: $pointed)
            .frame(height: 160)
            Text(L("hearing.curve_hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
