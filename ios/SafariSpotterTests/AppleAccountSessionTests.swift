import AuthenticationServices
import XCTest
@testable import SafariSpotter

@MainActor
final class AppleAccountSessionTests: XCTestCase {
    func testKeychainRemembersTheNameAfterSignOutUntilProfileRemoval() throws {
        let store = KeychainAppleAccountStore(service: "SafariSpotter.tests.\(UUID())")
        defer { try? store.remove() }
        let first = AppleAccountSession(storage: store)
        XCTAssertTrue(first.canReadProfile)
        XCTAssertNil(first.profile)
        first.signIn(userID: "test-apple-id", displayName: "  Safari Gast  ")
        XCTAssertEqual(first.profile?.displayName, "Safari Gast")
        first.changeName("Meine Safari")
        let reopened = AppleAccountSession(storage: store)
        XCTAssertEqual(reopened.profile?.displayName, "Meine Safari")
        reopened.signOut()
        XCTAssertNil(reopened.profile)
        let signedOut = AppleAccountSession(storage: store)
        XCTAssertNil(signedOut.profile)
        XCTAssertTrue(signedOut.hasSavedProfile)
        signedOut.signIn(userID: "test-apple-id", displayName: nil)
        XCTAssertEqual(signedOut.profile?.displayName, "Meine Safari")
        XCTAssertTrue(signedOut.removeProfile())
        XCTAssertNil(try store.read())
    }

    func testAnOfflineCheckRetainsTheLocalProfile() async {
        let store = TestAccountStorage()
        let session = AppleAccountSession(storage: store) { _ in throw URLError(.notConnectedToInternet) }
        session.signIn(userID: "test-apple-id", displayName: nil)
        await session.refresh()
        XCTAssertEqual(session.profile?.userID, "test-apple-id")
        XCTAssertNotNil(store.profile)
    }

    func testRevokingAppleAccessRemovesTheLocalProfile() async {
        let store = TestAccountStorage()
        let session = AppleAccountSession(storage: store) { _ in .revoked }
        session.signIn(userID: "test-apple-id", displayName: "Gast")
        await session.refresh()
        XCTAssertNil(session.profile)
        XCTAssertNil(store.profile)
        XCTAssertNotNil(session.message)
    }

    func testMissingAppleCredentialSignsOutWithoutErasingTheName() async {
        let store = TestAccountStorage()
        let session = AppleAccountSession(storage: store) { _ in .notFound }
        session.signIn(userID: "test-apple-id", displayName: "Gast")
        await session.refresh()
        XCTAssertNil(session.profile)
        XCTAssertEqual(store.profile?.displayName, "Gast")
    }

    func testUnsuccessfulSaveAndRemovalKeepThePreviousSession() {
        let store = TestAccountStorage()
        let session = AppleAccountSession(storage: store)
        session.signIn(userID: "old", displayName: "Gast")
        store.canWrite = false
        session.signIn(userID: "new", displayName: "Neu")
        XCTAssertEqual(session.profile?.userID, "old")
        session.signOut()
        XCTAssertFalse(session.removeProfile())
        XCTAssertEqual(session.profile?.userID, "old")
        XCTAssertNotNil(session.message)
    }
}

private final class TestAccountStorage: AppleAccountStorage {
    var profile: AppleAccountProfile?
    var canWrite = true

    func read() throws -> AppleAccountProfile? { profile }

    func save(_ profile: AppleAccountProfile) throws {
        guard canWrite else { throw CocoaError(.fileWriteNoPermission) }
        self.profile = profile
    }

    func remove() throws {
        guard canWrite else { throw CocoaError(.fileWriteNoPermission) }
        profile = nil
    }
}
