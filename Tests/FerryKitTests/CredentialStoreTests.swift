import Foundation
import Testing
@testable import FerryKit

private func makeStore() -> CredentialStore {
    CredentialStore(service: "ferry-test-\(UUID().uuidString)")
}

@Test func credentialSetThenGetRoundTrips() throws {
    let store = makeStore()
    let id = UUID()
    defer { try? store.removePassword(for: id) }
    try store.setPassword("s3cret", for: id)
    #expect(try store.password(for: id) == "s3cret")
}

@Test func credentialSetOverwritesExisting() throws {
    let store = makeStore()
    let id = UUID()
    defer { try? store.removePassword(for: id) }
    try store.setPassword("old", for: id)
    try store.setPassword("new", for: id)
    #expect(try store.password(for: id) == "new")
}

@Test func credentialRemoveThenGetReturnsNil() throws {
    let store = makeStore()
    let id = UUID()
    try store.setPassword("gone", for: id)
    try store.removePassword(for: id)
    #expect(try store.password(for: id) == nil)
}

@Test func credentialGetForUnknownIdReturnsNil() throws {
    #expect(try makeStore().password(for: UUID()) == nil)
}

@Test func credentialRemoveMissingIsNotAnError() throws {
    try makeStore().removePassword(for: UUID())
}
