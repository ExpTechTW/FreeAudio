import Foundation
import Testing
@testable import FreeAudio

@Suite struct UsageTests {
    private static let speakers = SourceKey(kind: .output, key: "spk")
    private static let microphone = SourceKey(kind: .input, key: "mic")
    private static let browser = SourceKey(kind: .playingApp, key: "org.mozilla.firefox")

    @MainActor @Test func addsUpTimeAndVolume() {
        let usage = UsageStats(store: nil)
        let now = Date()
        usage.record([
            .init(source: Self.speakers, name: "Speakers", volume: 0.5), .init(source: Self.microphone, name: "Microphone", volume: 0),
            .init(source: Self.browser, name: "Firefox", volume: 1.2),
        ], seconds: 1, at: now)
        usage.record([.init(source: Self.speakers, name: "Speakers", volume: 1)], seconds: 3, at: now)
        let day = usage.day(now)
        #expect(day.total(.output).seconds == 4 && day.total(.input).seconds == 1)
        #expect(day.records(.output).first?.uid == "spk" && day.total(.output).averageVolume == 0.875)
        #expect(day.apps.map(\.record.name) == ["Firefox"] && day.apps.first?.record.averageVolume == 1.2)
        usage.setTracking(false)
        usage.record([.init(source: Self.speakers, name: "Speakers", volume: 1)], seconds: 1, at: now)
        #expect(usage.day(now).total(.output).seconds == 4)
        // A line per source of this hour, after the header.
        #expect(usage.csv().split(separator: "\n").count == 4)
    }

    @Test func daysAndWeeks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.firstWeekday = 1
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23)))
        let number = Day.number(date, calendar: calendar)
        #expect(Day.label(number) == "2026-09-25" && Day.hour(date, calendar: calendar) == number * 24 + 23)
        #expect(Day.date(number, calendar: calendar) == calendar.startOfDay(for: date))
        let week = Day.week(of: date, calendar: calendar)
        #expect(week.count == 7 && week.map { Day.label(Day.number($0, calendar: calendar)) }.first == "2026-09-20")
        #expect(Day.lastSeven(until: date, calendar: calendar).map { Day.label(Day.number($0, calendar: calendar)) }.last == "2026-09-25")
    }

    @Test func civilDaysRoundTrip() {
        #expect(Day.civilDays(year: 1970, month: 1, day: 1) == 0)
        #expect(Day.civilDays(year: 2000, month: 3, day: 1) - Day.civilDays(year: 2000, month: 2, day: 28) == 2)
        #expect(Day.civilDays(year: 2100, month: 3, day: 1) - Day.civilDays(year: 2100, month: 2, day: 28) == 1)
        for days in stride(from: -800_000, through: 800_000, by: 997) {
            let date = Day.civilDate(days)
            #expect(Day.civilDays(year: date.year, month: date.month, day: date.day) == days)
        }
    }
}

@Suite struct HistoryTests {
    private static let headphones = SourceKey(kind: .output, key: "hp")
    private static let speakers = SourceKey(kind: .output, key: "spk")
    private static let player = SourceKey(kind: .playingApp, key: "org.mozilla.firefox")

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FreeAudioTests-\(UUID().uuidString)/history.sqlite")
    }

    @Test func varintsRoundTrip() {
        var packer = Packer()
        let values = [0, 1, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, Int(Int32.max), Int.max]
        for value in values { packer.varint(value) }
        packer.byte(200)
        #expect(packer.bytes.count == 1 + 1 + 1 + 2 + 2 + 3 + 3 + 4 + 5 + 9 + 1)
        var unpacker = Unpacker(packer.bytes)
        #expect(values.map { _ in unpacker.varint() } == values.map { Optional($0) })
        #expect(unpacker.byte() == 200 && unpacker.atEnd && unpacker.varint() == nil)
        // A varint cut short is broken, not a number.
        var broken = Unpacker([0x80, 0x80])
        #expect(broken.varint() == nil)
    }

    @Test func usageRecordsKeepMuteAndDevices() throws {
        let record = UsageRecord(name: "Firefox", seconds: 59.6, volumeSeconds: 40, mutedSeconds: 10, devices: [Self.headphones: 45, Self.speakers: 14.6])
        var packer = Packer()
        let numbers: [SourceKey: Int] = [Self.headphones: 3, Self.speakers: 300]
        record.pack(into: &packer) { numbers[$0] }
        #expect(packer.bytes.count <= 12)
        var unpacker = Unpacker(packer.bytes)
        let back = try #require(UsageRecord.unpack(&unpacker) { number in numbers.first { $0.value == number }?.key })
        #expect(unpacker.atEnd && back == UsageRecord(seconds: 60, volumeSeconds: 40, mutedSeconds: 10, devices: [Self.headphones: 45, Self.speakers: 15]))
    }

    @MainActor @Test func storesMinutesAndMergesAcrossRestarts() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let minute = 29_520_000
        do {
            let store = try #require(HistoryStore(file: file))
            // Fractions add up before they're rounded, and only when written.
            for _ in 0..<5 {
                store.add([Self.player: UsageRecord(name: "Firefox", seconds: 0.4, volumeSeconds: 0.2, devices: [Self.headphones: 0.4])], minute: minute)
            }
            store.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 10, volumeSeconds: 10)], minute: minute + 1)
            store.waitForWrites()
            let minutes = store.records(UsageRecord.self, minutes: minute..<minute + 2)
            #expect(minutes.map(\.minute) == [minute, minute + 1])
            #expect(minutes[0].records[Self.player] == UsageRecord(name: "Firefox", seconds: 2, volumeSeconds: 1, devices: [Self.headphones: 2]))
            store.close()
        }
        // After a restart, more for the same minute is added to what's there rather than replacing it.
        let store = try #require(HistoryStore(file: file))
        store.add([Self.player: UsageRecord(name: "Firefox Nightly", seconds: 3, volumeSeconds: 3, mutedSeconds: 1)], minute: minute)
        store.waitForWrites()
        let record = try #require(store.records(UsageRecord.self, minutes: minute..<minute + 1).first?.records[Self.player])
        #expect(record == UsageRecord(name: "Firefox Nightly", seconds: 5, volumeSeconds: 4, mutedSeconds: 1, devices: [Self.headphones: 2]))
    }

    @MainActor @Test func startsOverFromAnOlderLayout() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try #require(SQLiteConnection(path: file.path, readOnly: false))
        #expect(old.execute("CREATE TABLE usage(hour INTEGER PRIMARY KEY, data BLOB NOT NULL); INSERT INTO usage VALUES(1, x'0102');"))
        let store = try #require(HistoryStore(file: file))
        store.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 1)], minute: 60)
        store.waitForWrites()
        #expect(store.records(UsageRecord.self, minutes: 0..<Int.max).map(\.minute) == [60])
    }

    @MainActor @Test func prunesAndClears() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try #require(HistoryStore(file: file))
        for minute in [100, 200, 300] { store.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 1)], minute: minute) }
        store.prune(before: 250)
        store.waitForWrites()
        #expect(store.records(UsageRecord.self, minutes: 0..<Int.max).map(\.minute) == [300])
        store.removeAll(UsageRecord.self)
        store.waitForWrites()
        #expect(store.records(UsageRecord.self, minutes: 0..<Int.max).isEmpty)
    }

    @MainActor @Test func aHistoryKeepsTodayAndReadsOtherDaysFromTheStore() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try #require(HistoryStore(file: file))
        let evening = try #require(Day.gregorian.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 59, second: 30)))
        let history = History<UsageRecord>(store: store, now: evening)
        history.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 20)], at: evening)
        #expect(history.day(Day.number(evening))[Self.speakers]?.seconds == 20)
        #expect(history.minutes(of: Day.number(evening)).map(\.minute) == [Day.minute(evening)])
        // Past midnight, yesterday is read back from the store, and today starts empty.
        let morning = evening.addingTimeInterval(60)
        history.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 1)], at: morning)
        #expect(history.day(Day.number(morning))[Self.speakers]?.seconds == 1)
        #expect(history.day(Day.number(evening))[Self.speakers]?.seconds == 20)
        history.write()
        store.waitForWrites()
        let later = History<UsageRecord>(store: store, now: morning)
        #expect(later.day(Day.number(morning))[Self.speakers]?.seconds == 1)
        #expect(later.day(Day.number(evening))[Self.speakers]?.seconds == 20)
        #expect(later.stored(0..<Int.max).count == 2)
    }

    @MainActor @Test func aMinuteIsWrittenOnceItsOverEvenIfNothingFollows() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try #require(HistoryStore(file: file))
        let noon = try #require(Day.gregorian.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12, minute: 0, second: 10)))
        let history = History<UsageRecord>(store: store, now: noon)
        history.add([Self.speakers: UsageRecord(name: "Speakers", seconds: 1)], at: noon)
        history.writeIfOver(at: noon.addingTimeInterval(20))
        store.waitForWrites()
        #expect(store.records(UsageRecord.self, minutes: 0..<Int.max).isEmpty)
        history.writeIfOver(at: noon.addingTimeInterval(60))
        store.waitForWrites()
        #expect(store.records(UsageRecord.self, minutes: 0..<Int.max).map(\.minute) == [Day.minute(noon)])
    }

    @Test func consecutiveMinutesMakeRuns() {
        #expect(runs([9, 3, 4, 5, 12, 13]) == [3..<6, 9..<10, 12..<14])
        #expect(runs([]).isEmpty)
    }
}
