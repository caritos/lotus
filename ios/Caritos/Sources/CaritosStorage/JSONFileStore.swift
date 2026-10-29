import Foundation

/// Keeps one value in one file, `<name>.json`, as `{"version": N, "value": ...}`.
///
/// The directory is injected by the caller and only `<name>` is ever used inside it, so nothing
/// absolute is persisted and a save survives the app container moving. Writes are atomic (a
/// failed or interrupted save leaves the previous file intact). A file that cannot be decoded,
/// or carries another version (including a newer app's), is moved aside and `load()` returns
/// nil. The first copy is `<name>.corrupt.json`; later ones are `<name>.corrupt-2.json`,
/// `-3`, and so on, so no earlier copy is ever overwritten and nothing is deleted. If the
/// move itself fails, `load()` throws and the file stays where it is (a later `save`
/// still replaces it atomically).
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    private let directory: URL
    private let name: String
    private let version: Int

    public init(directory: URL, name: String, version: Int) {
        self.directory = directory
        self.name = name
        self.version = version
    }

    private var fileURL: URL { directory.appendingPathComponent("\(name).json") }
    private var corruptURL: URL { directory.appendingPathComponent("\(name).corrupt.json") }

    /// The saved value, or nil when there is no file or it was unusable (and moved aside).
    /// Throws only when an existing file cannot be read at all.
    public func load() throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(VersionHeader.self, from: data),
           header.version == version,
           let envelope = try? decoder.decode(Envelope<Value>.self, from: data) {
            return envelope.value
        }
        try moveAside()
        return nil
    }

    /// Writes atomically, creating the directory if needed.
    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: version, value: value))
        try data.write(to: fileURL, options: .atomic)
    }

    /// Moves the bad file to the first free aside name; never deletes anything.
    private func moveAside() throws {
        let manager = FileManager.default
        var target = corruptURL
        var n = 2
        while manager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(name).corrupt-\(n).json")
            n += 1
        }
        try manager.moveItem(at: fileURL, to: target)
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct Envelope<T: Codable>: Codable {
        let version: Int
        let value: T
    }
}
