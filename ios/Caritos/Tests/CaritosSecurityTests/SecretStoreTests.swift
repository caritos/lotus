import Foundation
import Testing
@testable import CaritosSecurity

@Suite struct InMemorySecretStoreTests {
    @Test func writeThenRead() throws {
        let store = InMemorySecretStore()
        try store.write("s3cret", account: "a")
        #expect(try store.read(account: "a") == "s3cret")
    }

    @Test func overwriteReplacesValue() throws {
        let store = InMemorySecretStore()
        try store.write("one", account: "a")
        try store.write("two", account: "a")
        #expect(try store.read(account: "a") == "two")
    }

    @Test func deleteRemovesAndMissingDeleteIsNoOp() throws {
        let store = InMemorySecretStore()
        try store.write("x", account: "a")
        try store.delete(account: "a")
        #expect(try store.read(account: "a") == nil)
        try store.delete(account: "a")
    }

    @Test func missingAccountReadsNil() throws {
        #expect(try InMemorySecretStore().read(account: "nope") == nil)
    }

    @Test func accountsAreIndependent() throws {
        let store = InMemorySecretStore()
        try store.write("1", account: "a")
        try store.write("2", account: "b")
        try store.delete(account: "a")
        #expect(try store.read(account: "b") == "2")
    }

    @Test func errorDescriptionHasStatusOnly() {
        let text = KeychainError.unexpectedStatus(-25300).localizedDescription
        #expect(text.contains("-25300"))
    }
}
