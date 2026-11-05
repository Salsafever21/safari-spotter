import XCTest
@testable import SafariSpotter

final class EncryptedBackupTests: XCTestCase {
    func testMultiChunkRoundTripAndRejectsWrongPasswordOrTampering() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ssbackup")
        let altered = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ssbackup")
        let payload = Data((0..<2_100_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: altered) }

        let encrypted = try EncryptedBackup.encrypt(source, password: "test passphrase with 20 characters")
        defer { try? FileManager.default.removeItem(at: encrypted) }
        XCTAssertTrue(try EncryptedBackup.isEncrypted(encrypted))
        XCTAssertFalse(try EncryptedBackup.isEncrypted(source))

        let restored = try EncryptedBackup.decrypt(encrypted, password: "test passphrase with 20 characters")
        defer { try? FileManager.default.removeItem(at: restored) }
        XCTAssertEqual(try Data(contentsOf: restored), payload)
        XCTAssertThrowsError(try EncryptedBackup.decrypt(encrypted, password: "a different test passphrase"))

        var changed = try Data(contentsOf: encrypted)
        changed[changed.count - 1] ^= 1
        try changed.write(to: altered)
        XCTAssertThrowsError(try EncryptedBackup.decrypt(altered, password: "test passphrase with 20 characters"))
    }
}
