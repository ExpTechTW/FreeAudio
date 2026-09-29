import Foundation

/// FreeAudio's log, in trem-monitor's format: a line per event, `[HH:MM:SS.mmm][LEVEL][tag]: message`, in a file per
/// hour at `logs/YYYY/MM/DD/HH.log` in FreeAudio's Application Support folder, all in local time. Day folders older
/// than `keptDays` are deleted at launch and every hour after.
///
/// Lines are written in order on a queue of their own, so logging never waits for the disk. Nothing is written
/// before `start`: previews and tests leave no log.
enum Log {
    enum Level: String, Sendable { case info = "INFO", warn = "WARN", error = "ERROR" }

    /// Today's folder and this many days before it are kept.
    static let keptDays = 3

    static func info(_ tag: String, _ message: String) { writer.write(.info, tag, message) }
    static func warn(_ tag: String, _ message: String) { writer.write(.warn, tag, message) }
    static func error(_ tag: String, _ message: String) { writer.write(.error, tag, message) }

    /// Starts writing into `folder`, e.g. `~/Library/Application Support/FreeAudio/logs`.
    static func start(folder: URL) { writer.start(folder) }

    static var folder: URL? { writer.folder }

    /// Returns once every line so far is in its file.
    static func flush() { writer.flush() }

    private static let writer = LogWriter()

    static func line(_ level: Level, _ tag: String, _ message: String, at date: Date, calendar: Calendar = Day.gregorian) -> String {
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let milliseconds = min((time.nanosecond ?? 0) / 1_000_000, 999)
        let stamp = String(format: "%02d:%02d:%02d.%03d", time.hour ?? 0, time.minute ?? 0, time.second ?? 0, milliseconds)
        return "[\(stamp)][\(level.rawValue)][\(tag)]: \(message)\n"
    }

    /// `YYYY/MM/DD/HH.log` under the folder.
    static func path(at date: Date, calendar: Calendar = Day.gregorian) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d/%02d/%02d/%02d.log", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
    }

    /// Deletes the day folders before `today` − `keptDays` (both `Day` numbers), and year and month folders left
    /// empty. Folders whose names aren't numbers are left alone. Returns how many days were deleted.
    @discardableResult
    static func prune(_ folder: URL, today: Int, keptDays: Int = keptDays) -> Int {
        let files = FileManager.default
        func numbered(_ url: URL) -> [(url: URL, number: Int)] {
            ((try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).compactMap { child in
                Int(child.lastPathComponent).map { (child, $0) }
            }
        }
        var deleted = 0
        for year in numbered(folder) {
            for month in numbered(year.url) {
                for day in numbered(month.url)
                where Day.civilDays(year: year.number, month: month.number, day: day.number) < today - keptDays {
                    if (try? files.removeItem(at: day.url)) != nil { deleted += 1 }
                }
                if (try? files.contentsOfDirectory(atPath: month.url.path))?.isEmpty == true { try? files.removeItem(at: month.url) }
            }
            if (try? files.contentsOfDirectory(atPath: year.url.path))?.isEmpty == true { try? files.removeItem(at: year.url) }
        }
        return deleted
    }
}

private final class LogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FreeAudio.log", qos: .utility)
    /// Only used on `queue`.
    private var root: URL?
    private var handle: FileHandle?
    private var openPath: String?
    private var lastPrune = Date.distantPast
    private let folderLock = NSLock()
    private var startedFolder: URL?

    var folder: URL? { folderLock.withLock { startedFolder } }

    func start(_ folder: URL) {
        folderLock.withLock { startedFolder = folder }
        queue.async { [self] in root = folder }
    }

    func write(_ level: Log.Level, _ tag: String, _ message: String) {
        // The time it happened, not the time it's written.
        let date = Date()
        queue.async { [self] in
            guard let root else { return }
            let line = Log.line(level, tag, message, at: date)
            #if DEBUG
            FileHandle.standardError.write(Data(line.utf8))
            #endif
            if date.timeIntervalSince(lastPrune) > 3_600 {
                lastPrune = date
                let deleted = Log.prune(root, today: Day.number(date))
                if deleted > 0 { append(Log.line(.info, "log", "清掉 \(deleted) 天份的舊日誌", at: date), to: root, at: date) }
            }
            append(line, to: root, at: date)
        }
    }

    func flush() { queue.sync {} }

    /// Only called on `queue`. A new hour opens a new file; a line that can't be written is dropped.
    private func append(_ line: String, to root: URL, at date: Date) {
        let path = Log.path(at: date)
        if path != openPath {
            try? handle?.close()
            handle = nil
            openPath = path
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if descriptor >= 0 { handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
        }
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}
