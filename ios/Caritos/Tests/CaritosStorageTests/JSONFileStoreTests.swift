import Foundation
import Testing
@testable import CaritosStorage

private struct Doc: Codable, Equatable, Sendable {
    var title: String
    var count: Int
}

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JSONFileStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    try? FileManager.default.removeItem(at: dir)
}

@Test func roundTrips() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    try store.save(Doc(title: "a", count: 2))
    #expect(try store.load() == Doc(title: "a", count: 2))
    try store.save(Doc(title: "b", count: 3))
    #expect(try store.load() == Doc(title: "b", count: 3))
}

@Test func missingFileLoadsNilAndCreatesNothing() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    #expect(try store.load() == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func saveCreatesMissingDirectory() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let nested = dir.appendingPathComponent("a/b")
    let store = JSONFileStore<Doc>(directory: nested, name: "doc", version: 1)
    try store.save(Doc(title: "x", count: 1))
    #expect(try store.load() == Doc(title: "x", count: 1))
}

private func checkMovedAside(_ bytes: Data) throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let file = dir.appendingPathComponent("doc.json")
    let aside = dir.appendingPathComponent("doc.corrupt.json")
    try bytes.write(to: file)
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try Data(contentsOf: aside) == bytes)
    try store.save(Doc(title: "ok", count: 9))
    #expect(try store.load() == Doc(title: "ok", count: 9))
}

@Test func emptyFileIsMovedAside() throws { try checkMovedAside(Data()) }

@Test func truncatedFileIsMovedAside() throws {
    try checkMovedAside(Data(#"{"version": 1, "value": {"title": "a", "co"#.utf8))
}

@Test func wrongVersionIsMovedAside() throws {
    try checkMovedAside(Data(#"{"version":2,"value":{"title":"a","count":1}}"#.utf8))
}

@Test func wrongShapeIsMovedAside() throws {
    try checkMovedAside(Data(#"{"version":1,"value":{"title":5}}"#.utf8))
}

@Test func successiveCorruptionsKeepEveryCopy() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let file = dir.appendingPathComponent("doc.json")
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    let first = Data("first garbage".utf8)
    let second = Data("second garbage".utf8)
    try first.write(to: file)
    #expect(try store.load() == nil)
    try second.write(to: file)
    #expect(try store.load() == nil)
    #expect(try Data(contentsOf: dir.appendingPathComponent("doc.corrupt.json")) == first)
    #expect(try Data(contentsOf: dir.appendingPathComponent("doc.corrupt-2.json")) == second)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func newerVersionFileIsPreservedByteForByte() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let file = dir.appendingPathComponent("doc.json")
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    let newer = Data(#"{"version":2,"value":{"title":"a","count":1,"extra":true}}"#.utf8)
    let garbage = Data("garbage".utf8)
    try newer.write(to: file)
    #expect(try store.load() == nil)
    try garbage.write(to: file)
    #expect(try store.load() == nil)
    #expect(try Data(contentsOf: dir.appendingPathComponent("doc.corrupt.json")) == newer)
    #expect(try Data(contentsOf: dir.appendingPathComponent("doc.corrupt-2.json")) == garbage)
}

@Test func failedMoveThrowsAndLeavesBadFileInPlace() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let file = dir.appendingPathComponent("doc.json")
    let bad = Data("garbage".utf8)
    try bad.write(to: file)
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    // Read-only directory: the file can be read but not renamed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    #expect(throws: (any Error).self) { try store.load() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(try Data(contentsOf: file) == bad)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.json"])
    try store.save(Doc(title: "ok", count: 1))
    #expect(try store.load() == Doc(title: "ok", count: 1))
}

@Test func missingDirectoryLoadsNilAndCreatesNothing() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let nested = dir.appendingPathComponent("nope")
    let store = JSONFileStore<Doc>(directory: nested, name: "doc", version: 1)
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: nested.path))
}

@Test func failedWriteThrowsAndKeepsPreviousFile() throws {
    let dir = try makeDir(); defer { cleanup(dir) }
    let store = JSONFileStore<Doc>(directory: dir, name: "doc", version: 1)
    try store.save(Doc(title: "old", count: 1))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    #expect(throws: (any Error).self) { try store.save(Doc(title: "new", count: 2)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(try store.load() == Doc(title: "old", count: 1))
}
