import Foundation

/// Where a database file lives. The absolute URL is recomputed from `FileManager` on every call and
/// must never be persisted: iOS can move the app container (a new UUID) across reinstalls while
/// carrying its contents over, so a stored absolute path would silently point at nothing.
public enum DatabaseLocation {
    /// `<Application Support>/<file>`, creating Application Support and any folder in `file`
    /// (for example `"Data/app.sqlite"`). The file itself is not created.
    public static func applicationSupport(file: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = directory.appendingPathComponent(file, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
}
