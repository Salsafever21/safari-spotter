import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Password protected, streaming wrapper around a complete SSBK1 archive.
/// SSBE1: magic(6), salt(16), PBKDF2 rounds(4 LE), chunk size(4 LE), plaintext size(8 LE),
/// then one AES-256-GCM combined box per chunk. Header and chunk index are authenticated data.
enum EncryptedBackup {
    enum BackupError: LocalizedError {
        case invalidFile, invalidPassword, invalidKey, truncated
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Die verschlüsselte Sicherung ist ungültig."
            case .invalidPassword: return "Das Passwort ist falsch oder die Sicherung ist beschädigt."
            case .invalidKey: return "Der Sicherungsschlüssel konnte nicht erzeugt werden."
            case .truncated: return "Die Sicherungsdatei ist unvollständig."
            }
        }
    }

    private static let magic = Data("SSBE1\n".utf8)
    private static let rounds: UInt32 = 210_000
    private static let chunkSize: UInt32 = 1_048_576
    private static let headerSize = 38

    static func isEncrypted(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try read(file, count: magic.count) == magic
    }

    static func encrypt(_ source: URL, password: String) throws -> URL {
        guard password.utf8.count >= 12 else { throw BackupError.invalidPassword }
        let size = try fileSize(source)
        guard size > 0, size <= 20_000_000_000 else { throw BackupError.invalidFile }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw BackupError.invalidKey }
        var header = magic
        header.append(contentsOf: salt)
        header.append(contentsOf: littleBytes(rounds))
        header.append(contentsOf: littleBytes(chunkSize))
        header.append(contentsOf: littleBytes(size))
        let key = try deriveKey(password: password, salt: Data(salt), rounds: rounds)
        let sourceFile = try FileHandle(forReadingFrom: source)
        defer { try? sourceFile.close() }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-spotter-\(UUID().uuidString)-geschuetzt.ssbackup")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw BackupError.invalidFile }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.write(contentsOf: header)
            var remaining = size
            var index: UInt64 = 0
            while remaining > 0 {
                let count = Int(min(remaining, UInt64(chunkSize)))
                guard let plain = try read(sourceFile, count: count) else { throw BackupError.truncated }
                var aad = header
                aad.append(contentsOf: littleBytes(index))
                let box = try AES.GCM.seal(plain, using: key, authenticating: aad)
                guard let combined = box.combined else { throw BackupError.invalidFile }
                try output.write(contentsOf: combined)
                remaining -= UInt64(count)
                index += 1
            }
            guard try sourceFile.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalidFile }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func decrypt(_ source: URL, password: String) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let header = try read(input, count: headerSize), header.prefix(6) == magic else { throw BackupError.invalidFile }
        let salt = Data(header[6..<22])
        let rounds = number(header[22..<26], as: UInt32.self)
        let chunkSize = number(header[26..<30], as: UInt32.self)
        let length = number(header[30..<38], as: UInt64.self)
        guard (100_000...1_000_000).contains(rounds), chunkSize > 0, chunkSize <= 2_097_152,
              length > 0, length <= 20_000_000_000 else { throw BackupError.invalidFile }
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-spotter-\(UUID().uuidString)-entschluesselt.ssbackup")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw BackupError.invalidFile }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var remaining = length
            var index: UInt64 = 0
            while remaining > 0 {
                let count = Int(min(remaining, UInt64(chunkSize)))
                guard let combined = try read(input, count: count + 28) else { throw BackupError.truncated }
                var aad = header
                aad.append(contentsOf: littleBytes(index))
                do {
                    let box = try AES.GCM.SealedBox(combined: combined)
                    let plain = try AES.GCM.open(box, using: key, authenticating: aad)
                    guard plain.count == count else { throw BackupError.invalidFile }
                    try output.write(contentsOf: plain)
                } catch { throw BackupError.invalidPassword }
                remaining -= UInt64(count)
                index += 1
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalidFile }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else { throw BackupError.invalidFile }
        return UInt64(size)
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { return nil }
            data.append(part)
        }
        return data
    }

    private static func littleBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func number<T: FixedWidthInteger>(_ bytes: Data.SubSequence, as: T.Type) -> T {
        bytes.enumerated().reduce(0) { $0 | (T($1.element) << ($1.offset * 8)) }
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { pass in
            salt.withUnsafeBytes { raw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, password.utf8.count,
                                    raw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                    &keyBytes, keyBytes.count)
            }
        }
        guard status == kCCSuccess else { throw BackupError.invalidKey }
        return SymmetricKey(data: Data(keyBytes))
    }
}
