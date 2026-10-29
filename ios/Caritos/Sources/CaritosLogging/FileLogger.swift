import Foundation
import os

/// File-backed log (one new file per logger instance, i.e. per app session) that also forwards
/// every line to `os.Logger`. Never throws: an unwritable directory makes `log` a silent no-op.
/// Callers must not pass secrets.
public final class FileLogger: @unchecked Sendable {
    private let directory: URL
    private let minimumLevel: LogLevel
    private let now: @Sendable () -> Date
    private let osLogger: Logger
    private let lock = NSLock()
    private let sessionFile: URL
    private var ready: Bool

    public init(
        directory: URL,
        minimumLevel: LogLevel = .info,
        subsystem: String = "com.caritos",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.minimumLevel = minimumLevel
        self.now = now
        self.osLogger = Logger(subsystem: subsystem, category: "app")
        // Timestamp sorts chronologically; the UUID suffix keeps same-second sessions apart.
        let stamp = Self.fileStamp(now())
        let unique = UUID().uuidString.prefix(8)
        self.sessionFile = directory.appendingPathComponent("log-\(stamp)-\(unique).log")
        var ok = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ok = FileManager.default.createFile(atPath: sessionFile.path, contents: Data())
        } catch {
            ok = false
        }
        self.ready = ok
    }

    /// This session's log file (it may not exist when the directory is unwritable).
    public var fileURL: URL { sessionFile }

    public func log(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: osLogger.debug("\(message, privacy: .public)")
        case .info: osLogger.info("\(message, privacy: .public)")
        case .warning: osLogger.warning("\(message, privacy: .public)")
        case .error: osLogger.error("\(message, privacy: .public)")
        }
        guard level >= minimumLevel else { return }
        let line = "[\(Self.isoStamp(now()))] [\(level.label)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard ready, let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: sessionFile)
        else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    }

    /// All log files in the directory, newest first. Empty when there is nothing to export.
    public func exportURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasPrefix("log-") && $0.hasSuffix(".log") }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }

    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}
