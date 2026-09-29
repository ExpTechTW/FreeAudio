import Foundation
import Testing
@testable import FreeAudio

@Suite struct LogTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0, nanosecond: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond)))
    }

    @Test func linesLookLikeTremMonitors() throws {
        let at = try date(2026, 9, 30, 4, 19, 34, nanosecond: 977_400_000)
        #expect(Log.line(.info, "device", "預設輸出：A → B", at: at, calendar: calendar) == "[04:19:34.977][INFO][device]: 預設輸出：A → B\n")
        #expect(Log.line(.warn, "mic", "x", at: try date(2026, 9, 30, 23, 5, 9), calendar: calendar) == "[23:05:09.000][WARN][mic]: x\n")
    }

    @Test func aFilePerHourInDatedFolders() throws {
        #expect(Log.path(at: try date(2026, 7, 29, 9, 59), calendar: calendar) == "2026/07/29/09.log")
        #expect(Log.path(at: try date(2026, 12, 31, 23), calendar: calendar) == "2026/12/31/23.log")
    }

    @Test func writesInOrderIntoThisHoursFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FreeAudioLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        Log.start(folder: root)
        for index in 0..<50 { Log.info("test", "第 \(index) 行") }
        Log.flush()
        let text = try String(contentsOf: root.appendingPathComponent(Log.path(at: Date())), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.contains("[test]") }
        #expect(lines.count == 50 && lines.first?.hasSuffix("[INFO][test]: 第 0 行") == true && lines.last?.hasSuffix("第 49 行") == true)
    }

    @Test func keepsTodayAndTheThreeDaysBefore() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("FreeAudioLogTests-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        for day in ["2026/09/26", "2026/09/27", "2026/09/28", "2026/09/30", "2026/08/31", "2025/12/31", "2026/09/notes"] {
            let folder = root.appendingPathComponent(day)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: folder.appendingPathComponent("10.log"))
        }
        let deleted = Log.prune(root, today: Day.civilDays(year: 2026, month: 9, day: 30), keptDays: 3)
        #expect(deleted == 3)
        let left = try files.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".log") }.sorted()
        #expect(left == ["2026/09/27/10.log", "2026/09/28/10.log", "2026/09/30/10.log", "2026/09/notes/10.log"])
        // A month or year with nothing left goes too.
        #expect(!files.fileExists(atPath: root.appendingPathComponent("2026/08").path))
        #expect(!files.fileExists(atPath: root.appendingPathComponent("2025").path))
    }
}
