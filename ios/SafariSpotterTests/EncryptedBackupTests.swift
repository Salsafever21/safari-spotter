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
        XCTAssertTrue(try EncryptedBackup.isStructurallyComplete(encrypted))
        XCTAssertFalse(try EncryptedBackup.isEncrypted(source))

        let restored = try EncryptedBackup.decrypt(encrypted, password: "test passphrase with 20 characters")
        defer { try? FileManager.default.removeItem(at: restored) }
        XCTAssertEqual(try Data(contentsOf: restored), payload)
        XCTAssertThrowsError(try EncryptedBackup.decrypt(encrypted, password: "a different test passphrase"))

        var changed = try Data(contentsOf: encrypted)
        changed[changed.count - 1] ^= 1
        try changed.write(to: altered)
        XCTAssertThrowsError(try EncryptedBackup.decrypt(altered, password: "test passphrase with 20 characters"))
        try Data(changed.dropLast(1)).write(to: altered)
        XCTAssertFalse(try EncryptedBackup.isStructurallyComplete(altered))
    }

    func testFinishedBackupsRemainAvailableAfterReopeningSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ssbackup")
        let payload = Data("all sightings, photos, clips and settings".utf8)
        try payload.write(to: source)
        let directory = root.appendingPathComponent("ProtectedBackups", isDirectory: true)
        let store = ProtectedBackupStore(directory: directory)
        let password = "a sufficiently long backup password"

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.save(source))
        let first = try store.save(EncryptedBackup.encrypt(source, password: password))
        let second = try store.save(EncryptedBackup.encrypt(source, password: password))
        XCTAssertEqual(Set(try ProtectedBackupStore(directory: directory).list()), Set([first, second]))

        let oldTemporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: oldTemporary, withIntermediateDirectories: true)
        let old = try EncryptedBackup.encrypt(source, password: password)
        try FileManager.default.moveItem(at: old, to: oldTemporary.appendingPathComponent(old.lastPathComponent))
        let recoveredStore = ProtectedBackupStore(directory: directory, temporaryDirectory: oldTemporary)
        let report = try recoveredStore.recoverTemporary()
        XCTAssertEqual(report.recovered, 1)
        XCTAssertEqual(report.incomplete, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try recoveredStore.list().count, 3)
        let interrupted = try EncryptedBackup.encrypt(source, password: password)
        let truncated = oldTemporary.appendingPathComponent(interrupted.lastPathComponent)
        let interruptedBytes = try Data(contentsOf: interrupted)
        try Data(interruptedBytes.dropLast(1)).write(to: truncated)
        try FileManager.default.removeItem(at: interrupted)
        let nextRecovery = try recoveredStore.recoverTemporary()
        XCTAssertEqual(nextRecovery.recovered, 0)
        XCTAssertEqual(nextRecovery.incomplete, 1)
        XCTAssertEqual(try recoveredStore.list().count, 3)

        let restored = try EncryptedBackup.decrypt(first, password: password)
        defer { try? FileManager.default.removeItem(at: restored) }
        XCTAssertEqual(try Data(contentsOf: restored), payload)
        XCTAssertThrowsError(try store.delete(source))
        try store.delete(first)
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertTrue(try store.list().contains(second))
    }
}
