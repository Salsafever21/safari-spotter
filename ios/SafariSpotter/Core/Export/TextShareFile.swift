import Foundation

/// Jede Freigabe erhält einen unveränderlichen Dateistand. Nur eigene, verlassene Exportdateien werden bereinigt.
enum TextShareFile {
    enum Kind: String, CaseIterable { case drive = "fahrt", sightings = "sichtungen" }

    static func create(_ content: String, kind: Kind, extension suffix: String,
                       directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("safari-spotter-\(kind.rawValue)-\(UUID().uuidString)").appendingPathExtension(suffix)
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func removeStale(in directory: URL = FileManager.default.temporaryDirectory,
                            before cutoff: Date = Date().addingTimeInterval(-3600)) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        for url in files where Kind.allCases.contains(where: { url.lastPathComponent.hasPrefix("safari-spotter-\($0.rawValue)-") })
            && ["gpx", "csv"].contains(url.pathExtension) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values.isRegularFile == true, let changed = values.contentModificationDate, changed < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
