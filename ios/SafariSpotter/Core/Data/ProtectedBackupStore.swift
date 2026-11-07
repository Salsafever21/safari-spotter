import Foundation

/// Keeps finished encrypted backups available after Settings or the app is closed.
/// Files remain local until the user shares or explicitly removes them.
struct ProtectedBackupStore {
    enum StoreError: LocalizedError {
        case invalidFile, duplicate, invalidPath

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Nur eine fertig verschlüsselte Safari-Spotter-Sicherung kann abgelegt werden."
            case .duplicate: return "Diese Sicherungsdatei ist bereits vorhanden."
            case .invalidPath: return "Diese Sicherungsdatei gehört nicht zum lokalen Sicherungsordner."
            }
        }
    }

    let directory: URL
    let temporaryDirectory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ProtectedBackups", isDirectory: true),
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        self.temporaryDirectory = temporaryDirectory
    }

    struct RecoveryReport {
        var recovered = 0
        var incomplete = 0
        var failed = 0
    }

    func recoverTemporary() throws -> RecoveryReport {
        let files = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
        var report = RecoveryReport()
        for file in files where Self.validName(file.lastPathComponent) {
            do {
                if try EncryptedBackup.isStructurallyComplete(file) {
                    _ = try save(file)
                    report.recovered += 1
                } else {
                    report.incomplete += 1
                }
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    func list() throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
            .filter { Self.validName($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
            }
    }

    func save(_ temporary: URL) throws -> URL {
        guard Self.validName(temporary.lastPathComponent), try EncryptedBackup.isStructurallyComplete(temporary) else {
            throw StoreError.invalidFile
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(temporary.lastPathComponent)
        guard !manager.fileExists(atPath: destination.path) else { throw StoreError.duplicate }
        // encrypt() already applied complete file protection. A same-volume move publishes only the finished file.
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }

    func delete(_ file: URL) throws {
        guard file.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              Self.validName(file.lastPathComponent) else { throw StoreError.invalidPath }
        try FileManager.default.removeItem(at: file)
    }

    private static func validName(_ name: String) -> Bool {
        let prefix = "safari-spotter-", suffix = "-geschuetzt.ssbackup"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let id = name.dropFirst(prefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(id)) != nil
    }
}
