import AppKit
import SwiftUI

/// Estimating the sound level at the ear from what the default output plays.
///
/// FreeAudio measures the A-weighted level of the audio sent to the device over each second (LAeq,1s, as sound level
/// meters and Android's sound dose do), then adds the device's volume in dB and how loud full scale plays on that kind
/// of device. Those references are typical values, not measurements of the user's hardware, so each device can be
/// calibrated by up to 12 dB either way.
enum Exposure {
    /// dB SPL of a full-scale signal at full volume.
    static func reference(for kind: AudioDevice.Kind) -> Double {
        switch kind {
        // IEC 62368-1 lets personal music players reach 100 dBA from a signal at -10 dBFS.
        case .headphones: 110
        // A laptop at arm's length.
        case .builtInSpeakers: 90
        case .speakers: 95
        }
    }

    /// Audio below this (dBFS) counts as silence.
    static let silence = -70.0
    static let calibrationRange = -12.0...12.0
    static let thresholds = [80, 85, 90]
    /// Seconds a level has to last before an alert.
    static let alertDelays: [Double] = [10, 30, 60, 120, 300]

    static func level(meanSquare: Double, volumeDecibels: Double, kind: AudioDevice.Kind, calibration: Double) -> Double {
        10 * log10(meanSquare) + volumeDecibels + reference(for: kind) + calibration
    }

    /// NIOSH's daily dose, in percent: 85 dBA for 8 hours is a full day, every 3 dB more halves the time, and levels
    /// under 80 dBA don't count.
    static func dailyDose(level: Double, seconds: Double) -> Double {
        guard level >= 80 else { return 0 }
        return 100 * seconds * pow(2, (level - 85) / 3) / 28_800
    }

    /// WHO-ITU H.870's weekly allowance, in percent: 80 dBA for 40 hours a week (1.6 Pa²h).
    static func weeklyDose(energy: Double) -> Double {
        100 * energy / (1e8 * 144_000)
    }

    /// When the volume control has no dB scale of its own, audio taper: level follows the square of the setting.
    static func approximateDecibels(volume: Double) -> Double {
        40 * log10(max(volume, 1e-4))
    }
}

/// What was heard over a stretch of time: an hour in the history, a day on screen.
struct HearingTally: Equatable, Sendable {
    /// Seconds heard at each whole dB.
    var levels: [Int: Double] = [:]
    /// Σ seconds × 10^(L/10): the sound energy.
    var energy = 0.0
    var peak = 0.0
    /// NIOSH daily dose, in percent.
    var dose = 0.0
    /// Σ offset × seconds, where the offset is what the level adds to the audio's own (dBFS): the device's volume in
    /// dB, its reference and its calibration. Kept so the audio and the volume can be told apart afterwards.
    var offsetSeconds = 0.0

    mutating func add(level: Double, seconds: Double, offset: Double = 0) {
        levels[Int(level.clamped(to: 0...140).rounded(.down)), default: 0] += seconds
        energy += seconds * pow(10, level / 10)
        peak = max(peak, level)
        dose += Exposure.dailyDose(level: level, seconds: seconds)
        offsetSeconds += offset * seconds
    }

    mutating func merge(_ other: HearingTally) {
        levels.merge(other.levels, uniquingKeysWith: +)
        energy += other.energy
        peak = max(peak, other.peak)
        dose += other.dose
        offsetSeconds += other.offsetSeconds
    }

    /// The average offset: the level minus it is how loud the audio itself was, in dBFS.
    var offset: Double? { monitored > 0 ? offsetSeconds / monitored : nil }

    var monitored: Double { levels.values.reduce(0, +) }
    var average: Double? { monitored > 0 ? 10 * log10(energy / monitored) : nil }

    /// Seconds from `level` dB up to, not including, `upper`.
    func seconds(from level: Int, below upper: Int = .max) -> Double {
        levels.reduce(0) { $1.key >= level && $1.key < upper ? $0 + $1.value : $0 }
    }
}

/// What one output device played in one hour.
struct HearingRecord: HistoryRecord {
    static let table = "hearing"

    var name = ""
    var tally = HearingTally()

    mutating func merge(_ other: HearingRecord) {
        if !other.name.isEmpty { name = other.name }
        tally.merge(other.tally)
    }

    /// The equivalent level and the peak in hundredths of a dB, the offset in tenths (zigzagged, as it can be
    /// negative), the dose in millionths of a day's, then the whole seconds at each dB from the quietest heard to the
    /// loudest: a minute of listening takes about 25 bytes.
    func pack(into packer: inout Packer, id: (SourceKey) -> Int?) {
        let monitored = tally.monitored
        packer.varint(monitored > 0 ? Int((1_000 * log10(tally.energy / monitored)).rounded()) : 0)
        packer.varint(Int((tally.peak * 100).rounded()))
        let offset = Int(((tally.offset ?? 0) * 10).rounded())
        packer.varint(offset >= 0 ? offset << 1 : (-offset << 1) - 1)
        packer.varint(Int((tally.dose * 1_000_000 / 100).rounded()))
        guard let low = tally.levels.keys.min(), let high = tally.levels.keys.max() else {
            packer.byte(0)
            packer.varint(0)
            return
        }
        packer.byte(low)
        packer.varint(high - low + 1)
        for level in low...high { packer.varint(Int((tally.levels[level] ?? 0).rounded())) }
    }

    static func unpack(_ unpacker: inout Unpacker, source: (Int) -> SourceKey?) -> HearingRecord? {
        guard let equivalent = unpacker.varint(), let peak = unpacker.varint(), let zigzag = unpacker.varint(),
              let dose = unpacker.varint(), let low = unpacker.byte(), let count = unpacker.varint(), count <= 256 else { return nil }
        var tally = HearingTally()
        for index in 0..<count {
            guard let seconds = unpacker.varint() else { return nil }
            if seconds > 0 { tally.levels[low + index] = Double(seconds) }
        }
        let offset = Double(zigzag & 1 == 0 ? zigzag >> 1 : -((zigzag + 1) >> 1)) / 10
        tally.energy = tally.monitored * pow(10, Double(equivalent) / 1_000)
        tally.peak = Double(peak) / 100
        tally.dose = Double(dose) * 100 / 1_000_000
        tally.offsetSeconds = offset * tally.monitored
        return HearingRecord(tally: tally)
    }
}

struct HearingSettings: StoredSettings {
    static let key = "FreeAudio.hearing.v1"

    var monitoring = false
    var threshold = 85
    var alertDelay = 30.0
    var alerts = true
    var weeklySummary = true
    /// `Calendar` weekday, 1 being Sunday.
    var summaryWeekday = 1
    var summaryHour = 18
    /// dB added to each output device's estimate, by UID.
    var calibration: [String: Double] = [:]
    var lastSummary: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.update(&monitoring, .monitoring)
        try container.update(&threshold, .threshold)
        try container.update(&alertDelay, .alertDelay)
        try container.update(&alerts, .alerts)
        try container.update(&weeklySummary, .weeklySummary)
        try container.update(&summaryWeekday, .summaryWeekday)
        try container.update(&summaryHour, .summaryHour)
        try container.update(&calibration, .calibration)
        lastSummary = try container.decodeIfPresent(Date.self, forKey: .lastSummary)
    }
}

/// Keeps the estimated level and each day's exposure, and warns about loud listening.
@MainActor
final class HearingMonitor: ObservableObject {
    /// What's playing now.
    struct Live: Equatable {
        /// dB SPL, `nil` while nothing is heard.
        var level: Double?
        var device: String
        var kind: AudioDevice.Kind
        var volume: Double
    }

    @Published private(set) var settings: HearingSettings
    @Published private(set) var live: Live?
    /// The last minute's levels, a second each, oldest first; `nil` where nothing was heard.
    @Published private(set) var lastMinute: [Double?] = []
    /// Moves on whenever the numbers do, so what shows them redraws.
    @Published private(set) var revision = 0
    /// Called when monitoring is switched on or off, which adds or removes the meter.
    var onMonitoringChange: (() -> Void)?
    private let history: History<HearingRecord>
    private let persists: Bool
    /// The last `settings.alertDelay` seconds, silence included, for the alert's running level.
    private var recent: [(seconds: Double, energy: Double)] = []
    private var alertArmed = true

    init(store: HistoryStore?) {
        persists = store != nil
        settings = store == nil ? HearingSettings() : .load()
        history = History(store: store)
    }

    func update(_ change: (inout HearingSettings) -> Void) {
        let monitoring = settings.monitoring
        change(&settings)
        settings.calibration = settings.calibration.filter { $0.value != 0 }
        if persists { settings.save() }
        if settings.monitoring != monitoring {
            live = nil
            lastMinute = []
            recent.removeAll()
            onMonitoringChange?()
        }
    }

    func calibration(for uid: String) -> Double { settings.calibration[uid] ?? 0 }

    /// Every output device's listening on `date`, together.
    func day(_ date: Date) -> HearingTally {
        history.day(Day.number(date)).values.reduce(into: HearingTally()) { $0.merge($1.tally) }
    }

    /// Adds what the meter measured over the last `seconds`. `meanSquare` is `nil` when there was nothing to measure.
    func record(meanSquare: Double?, seconds: Double, device: AudioDevice, volume: Double, volumeDecibels: Double, muted: Bool, at date: Date) {
        guard settings.monitoring else { return }
        var level: Double?
        let offset = volumeDecibels + Exposure.reference(for: device.kind) + calibration(for: device.uid)
        if let meanSquare, seconds > 0, !muted, volume > 0, 10 * log10(max(meanSquare, 1e-30)) > Exposure.silence {
            level = 10 * log10(meanSquare) + offset
        }
        let now = Live(level: level, device: device.name, kind: device.kind, volume: muted ? 0 : volume)
        if now != live { live = now }
        guard seconds > 0 else { return }
        lastMinute = Array((lastMinute + [level]).suffix(60))
        if let level {
            var record = HearingRecord(name: device.name)
            record.tally.add(level: level, seconds: seconds, offset: offset)
            history.add([SourceKey(kind: .output, key: device.uid): record], at: date)
            revision &+= 1
        }
        checkLoudness(level: level, seconds: seconds, device: device.name)
    }

    /// Alerts once the level over the last `alertDelay` seconds reaches the threshold, and again only after it has
    /// dropped 3 dB below it.
    private func checkLoudness(level: Double?, seconds: Double, device: String) {
        recent.append((seconds, level.map { seconds * pow(10, $0 / 10) } ?? 0))
        var covered = recent.reduce(0) { $0 + $1.seconds }
        while covered - recent[0].seconds >= settings.alertDelay {
            covered -= recent.removeFirst().seconds
        }
        guard covered >= settings.alertDelay * 0.95 else { return }
        let running = 10 * log10(max(recent.reduce(0) { $0 + $1.energy } / covered, 1e-30))
        let threshold = Double(settings.threshold)
        if alertArmed, running >= threshold {
            alertArmed = false
            if settings.alerts {
                HUD.shared.show(
                    symbol: "ear.trianglebadge.exclamationmark", tint: .orange, title: L("hearing.alert_title"),
                    message: LF("hearing.alert_body", device, Int(running.rounded()), durationText(settings.alertDelay))
                ) { SettingsWindow.shared.show(page: .hearing) }
            }
        } else if running < threshold - 3 {
            alertArmed = true
        }
    }

    /// Shows the week's summary at the chosen hour, once.
    func checkWeeklySummary(at date: Date, calendar: Calendar = .current) {
        guard settings.monitoring, settings.weeklySummary else { return }
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard parts.weekday == settings.summaryWeekday, parts.hour == settings.summaryHour,
              settings.lastSummary.map({ date.timeIntervalSince($0) > 3_600 }) ?? true else { return }
        update { $0.lastSummary = date }
        let week = Day.lastSeven(until: date, calendar: calendar).map { day($0) }
        let monitored = week.reduce(0) { $0 + $1.monitored }
        guard monitored > 0 else { return }
        let above = week.reduce(0) { $0 + $1.seconds(from: settings.threshold) }
        let dose = Exposure.weeklyDose(energy: week.reduce(0) { $0 + $1.energy })
        HUD.shared.show(
            symbol: "ear", tint: .pink, title: L("hearing.summary_title"),
            message: LF("hearing.summary_body", durationText(monitored), durationText(above), Int(dose.rounded()))
        ) { SettingsWindow.shared.show(page: .hearing) }
    }

    func reset() {
        history.removeAll()
        revision &+= 1
    }

    /// Writes what's been measured so far.
    func save() { history.write() }

    /// Called every second: writes a minute that's over.
    func tick(at date: Date) { history.writeIfOver(at: date) }

    /// The equivalent level and the loudest second of each `span` minutes of `date` with sound, for its curve; a whole
    /// day minute by minute is more than a chart can show.
    func minutes(_ date: Date, span: Int = 5) -> [(minute: Int, level: Double, peak: Double)] {
        let day = Day.number(date)
        var spans: [Int: HearingTally] = [:]
        for (minute, records) in history.minutes(of: day) {
            for record in records.values { spans[(minute - day * 1_440) / span * span, default: HearingTally()].merge(record.tally) }
        }
        return spans.sorted { $0.key < $1.key }.compactMap { start, tally in tally.average.map { (start, $0, tally.peak) } }
    }

    /// A line per output device and minute over the last 7 days up to `date`, or per device and hour over everything
    /// kept.
    func csv(week date: Date? = nil) -> String {
        var lines = ["date,time,device,name,monitored_seconds,average_db,peak_db,daily_dose_percent,audio_dbfs,seconds_80_85,seconds_85_90,seconds_90_up"]
        let minutes: Range<Int>
        if let date {
            let day = Day.number(date)
            minutes = Day.minutes(of: day - 6).lowerBound..<Day.minutes(of: day).upperBound
        } else {
            minutes = 0..<Int.max
        }
        var rows = history.stored(minutes)
        if date == nil {
            var hours: [Int: [SourceKey: HearingRecord]] = [:]
            for (minute, records) in rows {
                hours[minute / 60, default: [:]].merge(records) { var total = $0; total.merge($1); return total }
            }
            rows = hours.sorted { $0.key < $1.key }.map { ($0.key * 60, $0.value) }
        }
        for (minute, records) in rows {
            let time = date == nil ? String(format: "%02d:00", minute / 60 % 24) : String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
            for (key, record) in records.sorted(by: { $0.value.tally.monitored > $1.value.tally.monitored }) {
                let tally = record.tally
                let audio = tally.average.flatMap { average in tally.offset.map { String(format: "%.1f", average - $0) } }
                lines.append([
                    Day.label(minute / 1_440), time, csvField(key.key), csvField(record.name),
                    String(format: "%.0f", tally.monitored), tally.average.map { String(format: "%.1f", $0) } ?? "",
                    String(format: "%.1f", tally.peak), String(format: "%.3f", tally.dose), audio ?? "",
                    String(format: "%.0f", tally.seconds(from: 80, below: 85)), String(format: "%.0f", tally.seconds(from: 85, below: 90)),
                    String(format: "%.0f", tally.seconds(from: 90)),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
