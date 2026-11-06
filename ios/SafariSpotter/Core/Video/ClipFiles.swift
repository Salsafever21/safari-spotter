import Foundation

/// Metadaten eines Videoclips, gespeichert als `<id>.json` neben `<id>.mov` und `<id>.jpg` in `Application Support/Clips/`.
/// Bewusst nicht in SwiftData: Videos sind gross, das Datenmodell bleibt unverändert, und eine Sicherung kopiert drei Dateien.
///
/// Artenschutz: `lat`/`lon` sind immer auf das 10-km-Raster vergröbert (`coarse == true`), die Videodatei selbst trägt keinen Standort.
struct ClipRecord: Codable, Identifiable, Equatable {
    static let currentVersion = 1

    enum State: String, Codable {
        case recording   // Aufnahme läuft (oder lief, als die App beendet wurde)
        case complete    // sauber abgeschlossen
        case recovered   // nach Abbruch wiederhergestellt, abspielbar
        case damaged     // nach Abbruch nicht lesbar; Datei bleibt erhalten, wird nicht automatisch gelöscht
    }

    var version: Int = ClipRecord.currentVersion
    var id: UUID
    var createdAt: Date          // Beginn der Aufnahme
    var duration: Double         // Sekunden
    var width: Int               // Pixel der Videospur
    var height: Int
    var codec: String            // "hvc1" (HEVC) oder "avc1" (H.264)
    var fileSize: Int64          // Bytes der .mov-Datei
    var frames: Int              // geschriebene Bilder
    var droppedFrames: Int       // von der Kamera oder dem Schreiber verworfene Bilder während der Aufnahme
    var burnedIn: Bool           // Rahmen und Namen ins Bild eingebrannt
    var trackingActive: Bool     // Tiererkennung lief beim Start
    var species: [String]        // während der Aufnahme sicher erkannte Arten (sortiert, ohne Duplikate)
    var sightingIds: [UUID]      // Sichtungen, die während der Aufnahme entstanden oder gezählt wurden
    var sensitive: Bool          // eine der Arten ist sensibel (Nashorn)
    var lat: Double?             // immer vergröbert, oder ohne Standort
    var lon: Double?
    var coarse: Bool
    var lens: String?            // Objektiv beim Start ("Weitwinkel", "Tele", …)
    var state: State
    var file: String             // Dateiname der Videodatei, immer "<id>.mov"
    var thumbnail: String?       // Dateiname des Vorschaubilds, "<id>.jpg", falls vorhanden

    init(id: UUID, createdAt: Date, duration: Double = 0, width: Int = 0, height: Int = 0, codec: String = "",
         fileSize: Int64 = 0, frames: Int = 0, droppedFrames: Int = 0, burnedIn: Bool, trackingActive: Bool,
         species: [String] = [], sightingIds: [UUID] = [], sensitive: Bool = false, lat: Double? = nil, lon: Double? = nil,
         coarse: Bool = false, lens: String? = nil, state: State = .recording, thumbnail: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.duration = duration; self.width = width; self.height = height
        self.codec = codec; self.fileSize = fileSize; self.frames = frames; self.droppedFrames = droppedFrames
        self.burnedIn = burnedIn; self.trackingActive = trackingActive; self.species = species; self.sightingIds = sightingIds
        self.sensitive = sensitive; self.lat = lat; self.lon = lon; self.coarse = coarse; self.lens = lens; self.state = state
        self.file = ClipFiles.movieName(id); self.thumbnail = thumbnail
    }

    /// Abspielbar und für Galerie und Teilen geeignet
    var isPlayable: Bool { state == .complete || state == .recovered }
}

/// Ergebnis der Prüfung einer Videodatei (iOS: AVURLAsset), für die Wiederherstellung nach einem Abbruch
struct ClipProbe: Equatable {
    var duration: Double
    var width: Int
    var height: Int
}

enum ClipFileError: LocalizedError, Equatable {
    case invalidRecord(String)
    case missingMovie
    case sizeMismatch(expected: Int64, actual: Int64)
    var errorDescription: String? {
        switch self {
        case .invalidRecord(let detail): return "Clip-Metadaten ungültig: \(detail)"
        case .missingMovie: return "Videodatei fehlt"
        case .sizeMismatch(let e, let a): return "Videodatei hat \(a) statt \(e) Bytes"
        }
    }
}

/// Dateiablage der Clips. Nur Foundation, damit Sicherung und Wiederherstellung sie ohne AVFoundation nutzen können.
///
/// Struktur (Schnittstelle für Backup/Restore):
/// ```
/// Application Support/Clips/
///   <UUID>.mov    Video (HEVC oder H.264, optionaler Mikrofonton, ohne Standort-Metadaten)
///   <UUID>.json   ClipRecord, Version 1 (ISO-8601-Daten, sortierte Schlüssel)
///   <UUID>.jpg    Vorschaubild, längste Seite höchstens 480 px (optional)
/// ```
enum ClipFiles {
    static let folderName = "Clips"
    static func movieName(_ id: UUID) -> String { id.uuidString + ".mov" }
    static func metadataName(_ id: UUID) -> String { id.uuidString + ".json" }
    static func thumbnailName(_ id: UUID) -> String { id.uuidString + ".jpg" }

    /// `Application Support/Clips`, wird bei Bedarf angelegt
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func movieURL(_ id: UUID, in dir: URL) -> URL { dir.appendingPathComponent(movieName(id)) }
    static func metadataURL(_ id: UUID, in dir: URL) -> URL { dir.appendingPathComponent(metadataName(id)) }
    static func thumbnailURL(_ id: UUID, in dir: URL) -> URL { dir.appendingPathComponent(thumbnailName(id)) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// Metadaten atomar schreiben (eine halb geschriebene JSON-Datei kann es nicht geben)
    static func save(_ record: ClipRecord, in dir: URL) throws {
        try validate(record)
        try encoder.encode(record).write(to: metadataURL(record.id, in: dir), options: .atomic)
    }

    static func load(_ id: UUID, in dir: URL) -> ClipRecord? {
        guard let data = try? Data(contentsOf: metadataURL(id, in: dir)) else { return nil }
        return try? decoder.decode(ClipRecord.self, from: data)
    }

    /// Alle lesbaren Clips, neueste zuerst. Unlesbare JSON-Dateien werden übersprungen, nie gelöscht.
    static func list(in dir: URL) -> [ClipRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name -> ClipRecord? in
                guard let id = UUID(uuidString: String(name.dropLast(5))), let r = load(id, in: dir), r.id == id else { return nil }
                return r
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Videodateien ohne Metadaten (Abbruch vor dem ersten Schreiben der JSON-Datei)
    static func orphanMovies(in dir: URL) -> [UUID] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return names.filter { $0.hasSuffix(".mov") }
            .compactMap { UUID(uuidString: String($0.dropLast(4))) }
            .filter { !names.contains(metadataName($0)) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Nach einem Abbruch (App beendet, Absturz): Clips im Zustand `recording` und Videos ohne Metadaten prüfen und als
    /// `recovered` (abspielbar) oder `damaged` markieren. Löscht nichts. `excluding` ist eine gerade laufende Aufnahme.
    @discardableResult
    static func recoverInterrupted(in dir: URL, excluding active: UUID? = nil, probe: (URL) async -> ClipProbe?) async -> [ClipRecord] {
        var changed: [ClipRecord] = []
        for var r in list(in: dir) where r.state == .recording && r.id != active {
            let url = movieURL(r.id, in: dir)
            if let p = await probe(url), p.duration > 0 {
                r.state = .recovered; r.duration = p.duration; r.width = p.width; r.height = p.height
            } else { r.state = .damaged }
            r.fileSize = fileSize(url)
            if (try? save(r, in: dir)) != nil { changed.append(r) }
        }
        for id in orphanMovies(in: dir) where id != active {
            let url = movieURL(id, in: dir)
            let created = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date) ?? Date()
            var r = ClipRecord(id: id, createdAt: created, burnedIn: false, trackingActive: false, state: .damaged)
            if let p = await probe(url), p.duration > 0 { r.state = .recovered; r.duration = p.duration; r.width = p.width; r.height = p.height }
            r.fileSize = fileSize(url)
            if (try? save(r, in: dir)) != nil { changed.append(r) }
        }
        return changed
    }

    /// Clip vollständig löschen (Video, Metadaten, Vorschaubild); nur auf ausdrücklichen Wunsch aus der Galerie
    static func delete(_ id: UUID, in dir: URL) throws {
        for url in [movieURL(id, in: dir), metadataURL(id, in: dir), thumbnailURL(id, in: dir)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Wiederherstellung aus einer Sicherung. Idempotent: Existiert der Clip schon, bleibt er unverändert und wird zurückgegeben.
    /// Prüft Dateiname und (falls bekannt) die Grösse der Videodatei; kopiert erst Video und Bild, dann die Metadaten.
    @discardableResult
    static func install(movie source: URL, record: ClipRecord, thumbnail: Data?, in dir: URL) throws -> ClipRecord {
        if let existing = load(record.id, in: dir) { return existing }
        try validate(record)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ClipFileError.missingMovie }
        let size = fileSize(source)
        if record.fileSize > 0 && size != record.fileSize { throw ClipFileError.sizeMismatch(expected: record.fileSize, actual: size) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = movieURL(record.id, in: dir)
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
        var r = record
        r.fileSize = size
        r.state = record.state == .recording ? .recovered : record.state
        if let thumbnail {
            try thumbnail.write(to: thumbnailURL(record.id, in: dir), options: .atomic)
            r.thumbnail = thumbnailName(record.id)
        } else if !FileManager.default.fileExists(atPath: thumbnailURL(record.id, in: dir).path) {
            r.thumbnail = nil
        }
        try save(r, in: dir)
        return r
    }

    /// Freier Speicher für eine Aufnahme; nil, wenn das System ihn nicht nennt (dann wird nicht blockiert)
    static func availableCapacity(at dir: URL) -> Int64? {
        #if os(iOS) || os(macOS)
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    /// Start einer Aufnahme erst ab 1 GB frei, laufende Aufnahme endet unter 300 MB
    static let minimumFreeToStart: Int64 = 1_000_000_000
    static let minimumFreeWhileRecording: Int64 = 300_000_000
    static func hasRoom(available: Int64?, minimum: Int64) -> Bool { available.map { $0 >= minimum } ?? true }

    private static func validate(_ r: ClipRecord) throws {
        guard r.version >= 1 else { throw ClipFileError.invalidRecord("Version") }
        guard r.file == movieName(r.id) else { throw ClipFileError.invalidRecord("Dateiname") }
        if let t = r.thumbnail, t != thumbnailName(r.id) { throw ClipFileError.invalidRecord("Vorschaubild") }
        // Artenschutz: Clips dürfen nur vergröberte Positionen tragen
        if r.lat != nil || r.lon != nil { guard r.lat != nil, r.lon != nil, r.coarse else { throw ClipFileError.invalidRecord("Standort nicht vergröbert") } }
    }
}
