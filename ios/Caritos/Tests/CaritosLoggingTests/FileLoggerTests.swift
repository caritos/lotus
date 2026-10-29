import Foundation
import Testing
@testable import CaritosLogging

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("caritos-log-\(UUID().uuidString)")
}

private func clock(_ seconds: TimeInterval) -> @Sendable () -> Date {
    { Date(timeIntervalSince1970: seconds) }
}

@Test func belowMinimumLevelIsNotWritten() throws {
    let dir = tempDir()
    let logger = FileLogger(directory: dir, minimumLevel: .warning, now: clock(1_700_000_000))
    logger.log(.debug, "hidden-debug")
    logger.log(.info, "hidden-info")
    logger.log(.warning, "shown-warning")
    logger.log(.error, "shown-error")
    let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
    #expect(!text.contains("hidden"))
    #expect(text.contains("shown-warning"))
    #expect(text.contains("shown-error"))
}

@Test func linesCarryTimestampLevelAndMessageInOrder() throws {
    let dir = tempDir()
    let logger = FileLogger(directory: dir, now: clock(1_700_000_000))
    logger.log(.info, "first")
    logger.log(.error, "second")
    let lines = try String(contentsOf: logger.fileURL, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0] == "[2023-11-14T22:13:20Z] [INFO] first")
    #expect(lines[1] == "[2023-11-14T22:13:20Z] [ERROR] second")
}

@Test func secondLoggerWritesNewSessionFileAndExportListsNewestFirst() throws {
    let dir = tempDir()
    let a = FileLogger(directory: dir, now: clock(1_700_000_000))
    a.log(.info, "from-a")
    let b = FileLogger(directory: dir, now: clock(1_700_000_100))
    b.log(.info, "from-b")
    #expect(a.fileURL != b.fileURL)
    let urls = b.exportURLs()
    #expect(urls.count == 2)
    #expect(urls[0].lastPathComponent == b.fileURL.lastPathComponent)
    #expect(urls[1].lastPathComponent == a.fileURL.lastPathComponent)
    let textA = try String(contentsOf: a.fileURL, encoding: .utf8)
    #expect(textA.contains("from-a"))
    #expect(!textA.contains("from-b"))
}

@Test func unwritableDirectoryIsSilentNoOp() {
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("caritos-file-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: blocker.path, contents: Data())
    // A directory path beneath a regular file can never be created.
    let logger = FileLogger(directory: blocker.appendingPathComponent("logs"))
    logger.log(.error, "nobody hears this")
    #expect(logger.exportURLs().isEmpty)
}

@Test func levelsAreOrdered() {
    #expect(LogLevel.debug < .info)
    #expect(LogLevel.info < .warning)
    #expect(LogLevel.warning < .error)
}
