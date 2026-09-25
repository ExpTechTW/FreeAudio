import Foundation
import SQLite3

/// Local calendar days, hours and minutes as plain numbers, which key every history: a day counts from 1970-01-01 of
/// the Gregorian calendar, an hour is its day × 24 + the hour of the day, and a minute its hour × 60 + the minute, all
/// in the Mac's time zone.
enum Day {
    static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// `calendar` has to be Gregorian; other calendars count their years differently.
    static func number(_ date: Date, calendar: Calendar = gregorian) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return civilDays(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func hour(_ date: Date, calendar: Calendar = gregorian) -> Int {
        number(date, calendar: calendar) * 24 + calendar.component(.hour, from: date)
    }

    static func minute(_ date: Date, calendar: Calendar = gregorian) -> Int {
        hour(date, calendar: calendar) * 60 + calendar.component(.minute, from: date)
    }

    /// The minutes of day `number`.
    static func minutes(of number: Int) -> Range<Int> { number * 1_440..<(number + 1) * 1_440 }

    /// The start of day `number`.
    static func date(_ number: Int, calendar: Calendar = gregorian) -> Date {
        let (year, month, day) = civilDate(number)
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: Double(number) * 86_400)
    }

    /// `2026-09-25`, for exports.
    static func label(_ number: Int) -> String {
        let (year, month, day) = civilDate(number)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The seven days of the week `date` is in, starting on the calendar's first weekday.
    static func week(of date: Date, calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// `date` and the six days before it.
    static func lastSeven(until date: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        return (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Days from 1970-01-01 (Howard Hinnant's `days_from_civil`).
    static func civilDays(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }

    static func civilDate(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * monthIndex + 2) / 5 + 1)
    }
}

// MARK: - Binary

/// Writes the history's binary format: bytes, and unsigned varints (LEB128) that take one byte below 128, two below
/// 16 384 and three below 2 097 152.
struct Packer {
    private(set) var bytes: [UInt8] = []

    mutating func byte(_ value: Int) {
        bytes.append(UInt8(clamping: value))
    }

    mutating func varint(_ value: Int) {
        var rest = UInt64(max(value, 0))
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }
}

/// Reads what `Packer` wrote; `nil` once the data runs out or is broken.
struct Unpacker {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var atEnd: Bool { offset >= bytes.count }

    mutating func byte() -> Int? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    mutating func varint() -> Int? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return Int(clamping: value) }
            shift += 7
        }
        return nil
    }
}

// MARK: - SQLite

/// One SQLite connection, used from one thread at a time.
final class SQLiteConnection {
    enum Value {
        case int(Int)
        case text(String)
        case blob([UInt8])
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func blob(_ column: Int32) -> [UInt8] {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return [] }
            return Array(UnsafeRawBufferPointer(start: bytes, count: count))
        }
    }

    private let handle: OpaquePointer

    init?(path: String, readOnly: Bool) {
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        self.handle = handle
    }

    deinit { sqlite3_close_v2(handle) }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Runs one statement with `values` bound in order, handing each result row to `row`.
    @discardableResult
    func run(_ sql: String, _ values: [Value] = [], row: (Row) -> Void = { _ in }) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(statement, position, Int64(number))
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, transient)
            case .blob(let bytes):
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(Row(statement: statement))
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }
}

/// Has SQLite copy what's bound.
nonisolated(unsafe) private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - History

/// What a history row counts: an output or input device, or an app playing or recording.
struct SourceKey: Hashable, Sendable {
    enum Kind: Int, Sendable {
        case output, input, playingApp, recordingApp
    }

    let kind: Kind
    /// A device's UID, or an app's bundle identifier.
    let key: String
}

/// What a history keeps about one source in one minute.
protocol HistoryRecord: Sendable {
    /// The column of the minute's row it's kept in.
    static var table: String { get }
    init()
    /// The source's name when it was last seen.
    var name: String { get set }
    mutating func merge(_ other: Self)
    /// Writes the record's numbers; `id` numbers the other sources it refers to.
    func pack(into packer: inout Packer, id: (SourceKey) -> Int?)
    /// Reads what `pack` wrote; `nil` if the data is broken.
    static func unpack(_ unpacker: inout Unpacker, source: (Int) -> SourceKey?) -> Self?
}

/// Sources by the small number rows refer to them by.
private struct Sources {
    var byID: [Int: (key: SourceKey, name: String)] = [:]
    var byKey: [SourceKey: (id: Int, name: String)] = [:]

    mutating func load(_ connection: SQLiteConnection) {
        connection.run("SELECT id, kind, key, name FROM source") { row in
            guard let kind = SourceKey.Kind(rawValue: row.int(1)) else { return }
            let key = SourceKey(kind: kind, key: row.text(2))
            byID[row.int(0)] = (key, row.text(3))
            byKey[key] = (row.int(0), row.text(3))
        }
    }
}

/// Usage statistics in a SQLite database: a row per minute, keyed by `Day.minute`, with a column per kind
/// of record. A column holds each source's number followed by its record, packed (`Packer`); sources are named once, in
/// a table of their own. One row for everything in a minute keeps each row's own bookkeeping to once a minute.
///
/// Writing and reading are kept apart: writes run in order on a queue of their own, through their own connection,
/// and the interface reads through a second, read-only one. With the write-ahead log, a read never waits for a write,
/// nor a write for a read. Each connection keeps up to 4 MB of pages in memory.
final class HistoryStore: @unchecked Sendable {
    /// Minutes older than this many days are deleted.
    static let keptDays = 365
    /// `PRAGMA user_version` of the current layout; a database in another one starts over.
    private static let layout = 3
    /// The kinds of record, each a column of `minute`.
    private static let columns = [UsageRecord.table]

    private let queue = DispatchQueue(label: "FreeAudio.history", qos: .utility)
    /// Only used on `queue`.
    private let writer: SQLiteConnection
    private var writerSources = Sources()
    /// The minute each table was last written, with its exact totals: adding to the same minute again only rounds
    /// once, when it's written.
    private var open: [String: (minute: Int, records: Any)] = [:]
    /// Only used on the main actor.
    private let reader: SQLiteConnection
    private var readerSources = Sources()
    private let path: String

    init?(file: URL) {
        path = file.path
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let writer = SQLiteConnection(path: file.path, readOnly: false) else { return nil }
        var layout = 0
        writer.run("PRAGMA user_version") { layout = $0.int(0) }
        guard layout == Self.layout || writer.execute("""
                  DROP TABLE IF EXISTS usage;
                  DROP TABLE IF EXISTS hearing;
                  DROP TABLE IF EXISTS minute;
                  DROP TABLE IF EXISTS source;
                  PRAGMA user_version = \(Self.layout);
                  """),
              // Takes effect only before the first table exists: the pages of deleted minutes can then be given back.
              writer.execute("PRAGMA auto_vacuum = INCREMENTAL"),
              writer.execute("""
                  PRAGMA journal_mode = WAL;
                  PRAGMA synchronous = NORMAL;
                  PRAGMA cache_size = -4096;
                  CREATE TABLE IF NOT EXISTS source(
                      id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, UNIQUE(kind, key));
                  CREATE TABLE IF NOT EXISTS minute(minute INTEGER PRIMARY KEY, \(Self.columns.map { "\($0) BLOB" }.joined(separator: ", ")));
                  """),
              let reader = SQLiteConnection(path: file.path, readOnly: true),
              reader.execute("PRAGMA cache_size = -4096") else { return nil }
        if layout != Self.layout { writer.execute("VACUUM") }
        self.writer = writer
        self.reader = reader
        writerSources.load(writer)
    }

    /// Adds `records` to minute `minute`, in the background.
    func add<Record: HistoryRecord>(_ records: [SourceKey: Record], minute: Int) {
        guard !records.isEmpty else { return }
        queue.async { [self] in write(records, minute: minute) }
    }

    /// The minutes in `minutes` that have records, oldest first. Minutes still being written may not be there yet
    /// (`waitForWrites`).
    @MainActor
    func records<Record: HistoryRecord>(_ type: Record.Type, minutes: Range<Int>) -> [(minute: Int, records: [SourceKey: Record])] {
        // The writer may have renamed a source since; there are only a few dozen of them.
        readerSources = Sources()
        readerSources.load(reader)
        return Self.read(type, minutes: minutes, from: reader, sources: &readerSources)
    }

    /// Deletes the minutes before `minute`, and gives their space back.
    func prune(before minute: Int) {
        queue.async { [self] in
            writer.run("DELETE FROM minute WHERE minute < ?", [.int(minute)])
            writer.execute("PRAGMA incremental_vacuum")
        }
    }

    /// Deletes every record of a kind.
    func removeAll<Record: HistoryRecord>(_ type: Record.Type) {
        queue.async { [self] in
            open[Record.table] = nil
            let empty = Self.columns.map { "\($0) IS NULL" }.joined(separator: " AND ")
            writer.execute("UPDATE minute SET \(Record.table) = NULL; DELETE FROM minute WHERE \(empty); PRAGMA incremental_vacuum;")
        }
    }

    /// Bytes on disk, the write-ahead log included.
    var size: Int {
        ["", "-wal"].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: path + $1)[.size] as? Int) ?? 0) }
    }

    /// Returns once everything added so far is written.
    func waitForWrites() {
        queue.sync {}
    }

    /// Writes what's left and moves the write-ahead log into the database, e.g. when FreeAudio quits.
    func close() {
        queue.sync { _ = writer.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    private func write<Record: HistoryRecord>(_ added: [SourceKey: Record], minute: Int) {
        var records: [SourceKey: Record]
        if let current = open[Record.table], current.minute == minute, let exact = current.records as? [SourceKey: Record] {
            records = exact
        } else {
            records = Self.read(Record.self, minutes: minute..<minute + 1, from: writer, sources: &writerSources).first?.records ?? [:]
        }
        for (key, record) in added { records[key, default: Record()].merge(record) }
        open[Record.table] = (minute, records)

        writer.execute("BEGIN")
        // Named first, so what the records refer to has a number.
        let numbered = records.compactMap { key, record in sourceID(key, name: record.name).map { ($0, record) } }
        var packer = Packer()
        for (id, record) in numbered.sorted(by: { $0.0 < $1.0 }) {
            packer.varint(id)
            record.pack(into: &packer) { sourceID($0, name: "") }
        }
        writer.run(
            "INSERT INTO minute(minute, \(Record.table)) VALUES(?, ?) ON CONFLICT(minute) DO UPDATE SET \(Record.table) = excluded.\(Record.table)",
            [.int(minute), .blob(packer.bytes)]
        )
        writer.execute("COMMIT")
    }

    /// The number rows refer to a source by; added, or renamed, as needed. An empty name keeps the one it has.
    private func sourceID(_ key: SourceKey, name: String) -> Int? {
        if let known = writerSources.byKey[key], name.isEmpty || known.name == name { return known.id }
        writer.run(
            "INSERT INTO source(kind, key, name) VALUES(?, ?, ?) ON CONFLICT(kind, key) DO UPDATE SET name = excluded.name WHERE excluded.name != ''",
            [.int(key.kind.rawValue), .text(key.key), .text(name)]
        )
        var found: (id: Int, name: String)?
        writer.run("SELECT id, name FROM source WHERE kind = ? AND key = ?", [.int(key.kind.rawValue), .text(key.key)]) { found = ($0.int(0), $0.text(1)) }
        if let found {
            writerSources.byKey[key] = found
            writerSources.byID[found.id] = (key, found.name)
        }
        return found?.id
    }

    private static func read<Record: HistoryRecord>(
        _ type: Record.Type, minutes: Range<Int>, from connection: SQLiteConnection, sources: inout Sources
    ) -> [(minute: Int, records: [SourceKey: Record])] {
        var rows: [(minute: Int, data: [UInt8])] = []
        connection.run(
            "SELECT minute, \(Record.table) FROM minute WHERE minute >= ? AND minute < ? AND \(Record.table) IS NOT NULL ORDER BY minute",
            [.int(minutes.lowerBound), .int(minutes.upperBound)]
        ) { rows.append(($0.int(0), $0.blob(1))) }
        var reloaded = false
        func source(_ id: Int) -> (key: SourceKey, name: String)? {
            // A source the other connection added since this one last looked.
            if sources.byID[id] == nil, !reloaded {
                sources.load(connection)
                reloaded = true
            }
            return sources.byID[id]
        }
        return rows.map { minute, data in
            var unpacker = Unpacker(data)
            var records: [SourceKey: Record] = [:]
            while !unpacker.atEnd, let id = unpacker.varint(), var record = Record.unpack(&unpacker, source: { source($0)?.key }) {
                guard let found = source(id) else { continue }
                record.name = found.name
                records[found.key, default: Record()].merge(record)
            }
            return (minute, records)
        }
    }
}

/// A history in front of its store: the minute being counted until it's over, then written; today, minute by minute
/// and in total; and the other days looked at. Without a store (previews, tests) it only keeps today.
@MainActor
final class History<Record: HistoryRecord> {
    typealias Minutes = [(minute: Int, records: [SourceKey: Record])]

    private let store: HistoryStore?
    private var pending: [SourceKey: Record] = [:]
    private var pendingMinute: Int?
    private var today: Int
    private var todayTotals: [SourceKey: Record] = [:]
    private var todayMinutes: [Int: [SourceKey: Record]] = [:]
    /// Other days' totals, and the minutes of the last other day looked at.
    private var totals: [Int: [SourceKey: Record]] = [:]
    private var shownMinutes: (day: Int, minutes: Minutes)?

    init(store: HistoryStore?, now: Date = Date()) {
        self.store = store
        today = Day.number(now)
        for (minute, records) in store?.records(Record.self, minutes: Day.minutes(of: today)) ?? [] {
            todayMinutes[minute] = records
            for (key, record) in records { todayTotals[key, default: Record()].merge(record) }
        }
        store?.prune(before: Day.minutes(of: today - HistoryStore.keptDays).lowerBound)
    }

    func add(_ records: [SourceKey: Record], at date: Date) {
        let minute = Day.minute(date)
        if let pendingMinute, pendingMinute != minute { write() }
        startDay(minute / 1_440)
        pendingMinute = minute
        for (key, record) in records { pending[key, default: Record()].merge(record) }
    }

    /// Writes the minute being counted once it's over, also when nothing came after it.
    func writeIfOver(at date: Date) {
        if let pendingMinute, pendingMinute != Day.minute(date) { write() }
    }

    /// Hands the minute being counted to the store; it's also written when the next minute begins.
    func write() {
        guard let minute = pendingMinute, !pending.isEmpty else { return }
        store?.add(pending, minute: minute)
        if minute / 1_440 == today {
            todayMinutes[minute, default: [:]].merge(pending) { var total = $0; total.merge($1); return total }
            for (key, record) in pending { todayTotals[key, default: Record()].merge(record) }
        } else {
            // Written for another day, e.g. after the clock went back: read that day again when it's next shown.
            totals[minute / 1_440] = nil
            shownMinutes = nil
        }
        pending = [:]
        pendingMinute = nil
    }

    /// Every source's totals for day `number`.
    func day(_ number: Int) -> [SourceKey: Record] {
        if number == today {
            guard let pendingMinute, pendingMinute / 1_440 == today else { return todayTotals }
            return todayTotals.merging(pending) { var total = $0; total.merge($1); return total }
        }
        if let cached = totals[number] { return cached }
        var sum: [SourceKey: Record] = [:]
        for (_, records) in minutes(of: number) {
            for (key, record) in records { sum[key, default: Record()].merge(record) }
        }
        totals[number] = sum
        return sum
    }

    /// Day `number` minute by minute, oldest first.
    func minutes(of number: Int) -> Minutes {
        if number == today {
            var minutes = todayMinutes
            if let pendingMinute, pendingMinute / 1_440 == today { minutes[pendingMinute, default: [:]].merge(pending) { var total = $0; total.merge($1); return total } }
            return minutes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        if let shownMinutes, shownMinutes.day == number { return shownMinutes.minutes }
        store?.waitForWrites()
        let minutes = store?.records(Record.self, minutes: Day.minutes(of: number)) ?? []
        shownMinutes = (number, minutes)
        return minutes
    }

    /// Every minute kept in `minutes`, oldest first.
    func stored(_ minutes: Range<Int>) -> Minutes {
        write()
        guard let store else { return self.minutes(of: today).filter { minutes.contains($0.minute) } }
        store.waitForWrites()
        return store.records(Record.self, minutes: minutes)
    }

    func removeAll() {
        pending = [:]
        pendingMinute = nil
        todayTotals = [:]
        todayMinutes = [:]
        totals = [:]
        shownMinutes = nil
        store?.removeAll(Record.self)
    }

    private func startDay(_ number: Int) {
        guard number != today else { return }
        totals[today] = todayTotals
        today = number
        todayTotals = [:]
        todayMinutes = [:]
        totals[number] = nil
        shownMinutes = nil
        store?.prune(before: Day.minutes(of: number - HistoryStore.keptDays).lowerBound)
    }
}

/// Consecutive minutes run together: `[3, 4, 5, 9]` is 3..<6 and 9..<10.
func runs(_ minutes: [Int]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    for minute in minutes.sorted() {
        if let last = runs.last, last.upperBound == minute {
            runs[runs.count - 1] = last.lowerBound..<minute + 1
        } else {
            runs.append(minute..<minute + 1)
        }
    }
    return runs
}

/// Settings kept as JSON in the user defaults.
protocol StoredSettings: Codable, Equatable {
    init()
    static var key: String { get }
}

extension StoredSettings {
    static func load() -> Self {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Text for a CSV cell.
func csvField(_ text: String) -> String {
    text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
}
