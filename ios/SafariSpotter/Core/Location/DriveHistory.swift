import Foundation

/// Zeitliche Zuordnung ohne neue Datenbankfelder: auch ältere und importierte Fahrten bleiben nutzbar.
struct DriveWindow {
    let start: Date
    let end: Date

    enum WindowError: LocalizedError {
        case invalidDates
        var errorDescription: String? { "Der gespeicherte Fahrtzeitraum ist ungültig." }
    }

    init(start: Date, end: Date) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= start else {
            throw WindowError.invalidDates
        }
        self.start = start; self.end = end
    }

    func contains(_ date: Date) -> Bool { date >= start && date <= end }
    func sightings(from all: [Sighting]) -> [Sighting] { all.filter { contains($0.t) } }
    func photos(from all: [PhotoItem]) -> [PhotoItem] { all.filter { contains($0.t) } }
    func points(from all: [TrackPoint]) -> [TrackPoint] {
        all.filter { $0.t >= start.timeIntervalSince1970 && $0.t <= end.timeIntervalSince1970 }.sorted { $0.t < $1.t }
    }
}

/// Der sichtbare Fahrtinhalt und der Schutzkontext für den Export sind getrennt:
/// Eine Nashorn-Sichtung knapp ausserhalb der Fahrt muss die angrenzende Spur trotzdem schützen.
enum DriveHistoryExport {
    private static let prefix = "safari-spotter-fahrt-"

    static func gpx(drive: Drive, sightings: [Sighting], photos: [PhotoItem] = [], catalog: SpeciesCatalog) throws -> String {
        let window = try DriveWindow(start: drive.startedAt, end: drive.endedAt)
        let points = window.points(from: try drive.decodedPoints())
        return Exporters.gpx(points: points, sightings: window.sightings(from: sightings).sorted { $0.t < $1.t },
                             catalog: catalog, version: "1.0", privacySightings: sightings, privacyPhotos: photos)
    }

    static func csv(drive: Drive, sightings: [Sighting], photos: [PhotoItem] = [], catalog: SpeciesCatalog) throws -> String {
        let window = try DriveWindow(start: drive.startedAt, end: drive.endedAt)
        return Exporters.csv(sightings: window.sightings(from: sightings).sorted { $0.t < $1.t }, catalog: catalog,
                             privacySightings: sightings, privacyPhotos: photos)
    }

    static func createFile(_ content: String, extension suffix: String,
                           directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent(prefix + UUID().uuidString).appendingPathExtension(suffix)
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
        for url in files where url.lastPathComponent.hasPrefix(prefix) && ["gpx", "csv"].contains(url.pathExtension) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values.isRegularFile == true, let changed = values.contentModificationDate, changed < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
