import Foundation

/// How long a source was in use, at what volume, and for an app, on which devices.
struct UsageRecord: HistoryRecord, Equatable {
    static let table = "usage"

    var name = ""
    var seconds = 0.0
    /// Σ volume × seconds, for the time-weighted average: a device's volume is 0–1, an app's 0–2 (its volume in
    /// FreeAudio), and a recording app's is its microphone's. Muted counts as 0.
    var volumeSeconds = 0.0
    var mutedSeconds = 0.0
    /// An app's seconds on each device it played to or recorded from.
    var devices: [SourceKey: Double] = [:]

    var averageVolume: Double? { seconds > 0 ? volumeSeconds / seconds : nil }

    mutating func merge(_ other: UsageRecord) {
        if !other.name.isEmpty { name = other.name }
        seconds += other.seconds
        volumeSeconds += other.volumeSeconds
        mutedSeconds += other.mutedSeconds
        devices.merge(other.devices, uniquingKeysWith: +)
    }

    /// Whole seconds, the volume in hundredths, the muted seconds, then each device by number with its seconds: a
    /// device's minute takes 4 bytes, an app's 2 more per device.
    func pack(into packer: inout Packer, id: (SourceKey) -> Int?) {
        packer.varint(Int(seconds.rounded()))
        packer.varint(Int((volumeSeconds * 100).rounded()))
        packer.varint(Int(mutedSeconds.rounded()))
        let numbered = devices.compactMap { key, seconds in id(key).map { ($0, seconds) } }.sorted { $0.0 < $1.0 }
        packer.varint(numbered.count)
        for (number, seconds) in numbered {
            packer.varint(number)
            packer.varint(Int(seconds.rounded()))
        }
    }

    static func unpack(_ unpacker: inout Unpacker, source: (Int) -> SourceKey?) -> UsageRecord? {
        guard let seconds = unpacker.varint(), let volume = unpacker.varint(), let muted = unpacker.varint(),
              let count = unpacker.varint(), count < 256 else { return nil }
        var record = UsageRecord(seconds: Double(seconds), volumeSeconds: Double(volume) / 100, mutedSeconds: Double(muted))
        for _ in 0..<count {
            guard let number = unpacker.varint(), let seconds = unpacker.varint() else { return nil }
            if let device = source(number) { record.devices[device, default: 0] += Double(seconds) }
        }
        return record
    }
}

/// One day's use of every device and app.
struct UsageDay: Equatable {
    var records: [SourceKey: UsageRecord] = [:]

    /// The devices of a direction, most used first.
    func records(_ direction: DeviceDirection) -> [(uid: String, record: UsageRecord)] {
        let kind: SourceKey.Kind = direction == .output ? .output : .input
        return records.compactMap { $0.key.kind == kind ? ($0.key.key, $0.value) : nil }.sorted { $0.record.seconds > $1.record.seconds }
    }

    /// Apps that played or recorded, most used first.
    var apps: [(key: SourceKey, record: UsageRecord)] {
        records.filter { $0.key.kind == .playingApp || $0.key.kind == .recordingApp }
            .map { ($0.key, $0.value) }
            .sorted { $0.record.seconds > $1.record.seconds }
    }

    /// Every device of a direction together; devices used at the same time each count.
    func total(_ direction: DeviceDirection) -> UsageRecord {
        records(direction).reduce(into: UsageRecord()) { total, device in
            total.seconds += device.record.seconds
            total.volumeSeconds += device.record.volumeSeconds
            total.mutedSeconds += device.record.mutedSeconds
        }
    }
}

struct UsageSettings: StoredSettings {
    static let key = "FreeAudio.usage.v1"
    var tracking = true
}

/// When each device and app is in use: a device counts while an app plays to it or records from it. That's what apps
/// do rather than whether the device is running, which FreeAudio's own rendering keeps it doing.
@MainActor
final class UsageStats: ObservableObject {
    struct Use {
        let source: SourceKey
        let name: String
        let volume: Double
        var muted = false
        /// The devices an app plays to or records from.
        var devices: [SourceKey] = []
    }

    /// Minutes of use in each hour of a day.
    struct Hour: Identifiable {
        let hour: Int
        let direction: DeviceDirection
        let minutes: Double
        var id: String { "\(hour)-\(direction.key)" }
    }

    /// When a source was in use during a day, in runs of minutes after midnight.
    struct Lane: Identifiable {
        let source: SourceKey
        let name: String
        let seconds: Double
        let runs: [Range<Int>]
        var id: SourceKey { source }
    }

    @Published private(set) var settings: UsageSettings
    /// Moves on whenever the numbers do, so what shows them redraws.
    @Published private(set) var revision = 0
    private let history: History<UsageRecord>
    private let store: HistoryStore?
    private let persists: Bool

    /// The history's size on disk; `nil` when it's only kept in memory.
    var storedBytes: Int? { store?.size }

    init(store: HistoryStore?) {
        self.store = store
        persists = store != nil
        settings = store == nil ? UsageSettings() : .load()
        history = History(store: store)
    }

    func setTracking(_ on: Bool) {
        settings.tracking = on
        if persists { settings.save() }
    }

    func record(_ uses: [Use], seconds: Double, at date: Date) {
        guard settings.tracking, !uses.isEmpty, seconds > 0 else { return }
        var records: [SourceKey: UsageRecord] = [:]
        for use in uses {
            var record = UsageRecord(name: use.name, seconds: seconds, volumeSeconds: use.muted ? 0 : seconds * use.volume, mutedSeconds: use.muted ? seconds : 0)
            for device in use.devices { record.devices[device, default: 0] += seconds }
            records[use.source, default: UsageRecord()].merge(record)
        }
        history.add(records, at: date)
        revision &+= 1
    }

    func day(_ date: Date) -> UsageDay { UsageDay(records: history.day(Day.number(date))) }

    /// Minutes of output and input in each hour of `date`.
    func hours(_ date: Date) -> [Hour] {
        let day = Day.number(date)
        var output = [Double](repeating: 0, count: 24), input = [Double](repeating: 0, count: 24)
        for (minute, records) in history.minutes(of: day) {
            let hour = (minute - day * 1_440) / 60
            guard (0..<24).contains(hour) else { continue }
            // A minute counts once however many devices were in use.
            if let seconds = records.filter({ $0.key.kind == .output }).map(\.value.seconds).max() { output[hour] += seconds / 60 }
            if let seconds = records.filter({ $0.key.kind == .input }).map(\.value.seconds).max() { input[hour] += seconds / 60 }
        }
        return (0..<24).flatMap { [Hour(hour: $0, direction: .output, minutes: output[$0]), Hour(hour: $0, direction: .input, minutes: input[$0])] }
    }

    /// When each device and app was in use on `date`, most used first.
    func lanes(_ date: Date, limit: Int = 8) -> [Lane] {
        let day = Day.number(date)
        var minutes: [SourceKey: [Int]] = [:], seconds: [SourceKey: Double] = [:], names: [SourceKey: String] = [:]
        for (minute, records) in history.minutes(of: day) {
            for (key, record) in records where record.seconds >= 1 {
                minutes[key, default: []].append(minute - day * 1_440)
                seconds[key, default: 0] += record.seconds
                names[key] = record.name
            }
        }
        return minutes.map { Lane(source: $0.key, name: names[$0.key] ?? $0.key.key, seconds: seconds[$0.key] ?? 0, runs: runs($0.value)) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { $0 }
    }

    func reset() {
        history.removeAll()
        revision &+= 1
    }

    /// Writes what's been counted so far.
    func save() { history.write() }

    /// Called every second: writes a minute that's over.
    func tick(at date: Date) { history.writeIfOver(at: date) }

    /// A line per source and minute over the week of `date`, or per source and hour over everything kept.
    func csv(week date: Date? = nil) -> String {
        var lines = ["date,time,kind,id,name,seconds,average_volume_percent,muted_seconds,devices"]
        let minutes: Range<Int>
        if let date, let first = Day.week(of: date).first {
            let day = Day.number(first)
            minutes = Day.minutes(of: day).lowerBound..<Day.minutes(of: day + 6).upperBound
        } else {
            minutes = 0..<Int.max
        }
        var rows = history.stored(minutes)
        if date == nil {
            // Minutes add up into hours.
            var hours: [Int: [SourceKey: UsageRecord]] = [:]
            for (minute, records) in rows {
                hours[minute / 60, default: [:]].merge(records) { var total = $0; total.merge($1); return total }
            }
            rows = hours.sorted { $0.key < $1.key }.map { ($0.key * 60, $0.value) }
        }
        for (minute, records) in rows {
            let time = date == nil ? String(format: "%02d:00", minute / 60 % 24) : String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
            for (key, record) in records.sorted(by: { $0.value.seconds > $1.value.seconds }) {
                let kind = ["output", "input", "app_playing", "app_recording"][key.kind.rawValue]
                let devices = record.devices.sorted { $0.value > $1.value }.map { "\($0.key.key)=\(Int($0.value.rounded()))" }.joined(separator: ";")
                lines.append([
                    Day.label(minute / 1_440), time, kind, csvField(key.key), csvField(record.name), String(format: "%.0f", record.seconds),
                    record.averageVolume.map { String(format: "%.0f", $0 * 100) } ?? "", String(format: "%.0f", record.mutedSeconds), csvField(devices),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
