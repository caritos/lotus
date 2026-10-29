import Foundation
import Testing
@testable import CaritosSecurity

/// Touches the real login keychain, so it runs only with CARITOS_REAL_KEYCHAIN=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CARITOS_REAL_KEYCHAIN"] == "1"))
struct KeychainStoreTests {
    @Test func roundTripOverwriteAndDelete() throws {
        let service = "com.caritos.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let account = UUID().uuidString
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil)
        try store.write("one", account: account)
        #expect(try store.read(account: account) == "one")
        try store.write("two", account: account)
        #expect(try store.read(account: account) == "two")
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account)
    }

    @Test func servicesAreIsolated() throws {
        let a = KeychainStore(service: "com.caritos.tests.\(UUID().uuidString)")
        let b = KeychainStore(service: "com.caritos.tests.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { try? a.delete(account: account); try? b.delete(account: account) }
        try a.write("x", account: account)
        #expect(try b.read(account: account) == nil)
    }
}
