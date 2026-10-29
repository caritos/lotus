import Foundation

/// A store for small secrets (tokens, passwords) keyed by account.
/// By convention the account is a stable UUID string, never a value derived from the secret.
public protocol SecretStoring: Sendable {
    /// Returns nil when the account has no item. Throws on a real read failure.
    func read(account: String) throws -> String?
    /// Creates or replaces the item.
    func write(_ value: String, account: String) throws
    /// Removing a missing account is a no-op.
    func delete(account: String) throws
}
