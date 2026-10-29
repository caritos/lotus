import Foundation

/// Failures from the Keychain. Carries only the OSStatus, never a secret value.
public enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain error (status \(status))"
        }
    }
}

/// A thread-safe in-memory store for tests of apps. Not for production secrets.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    public func write(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = value
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }
}
