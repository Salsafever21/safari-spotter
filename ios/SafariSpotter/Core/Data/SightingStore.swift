import Foundation
import SwiftData

/// Schreibzugriffe auf Sichtungen, die Zählung und Artenschutz betreffen. Arbeitet mit dem `ModelContext` der App und wird
/// darum auf dem Main-Thread benutzt (UI, `CameraController` über `DispatchQueue.main`). Löscht nur, wenn die Korrektur
/// ausdrücklich "Kein Tier" sagt, und ändert das Datenmodell nicht.
struct SightingStore {
    let context: ModelContext
    let isSensitive: (String) -> Bool
    let saveContext: (ModelContext) throws -> Void
    let fetchPhotos: (ModelContext) throws -> [PhotoItem]

    enum StoreError: LocalizedError {
        case newSightingFailed
        var errorDescription: String? { "Korrigierte Sichtung konnte nicht gespeichert werden" }
    }

    init(context: ModelContext, isSensitive: @escaping (String) -> Bool,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
         fetchPhotos: @escaping (ModelContext) throws -> [PhotoItem] = { try $0.fetch(FetchDescriptor<PhotoItem>()) }) {
        self.context = context
        self.isSensitive = isSensitive
        self.saveContext = saveContext
        self.fetchPhotos = fetchPhotos
    }

    init(context: ModelContext, catalog: SpeciesCatalog,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
         fetchPhotos: @escaping (ModelContext) throws -> [PhotoItem] = { try $0.fetch(FetchDescriptor<PhotoItem>()) }) {
        self.init(context: context, isSensitive: { catalog.isSensitive(name: $0) },
                  saveContext: saveContext, fetchPhotos: fetchPhotos)
    }

    func sighting(id: UUID) throws -> Sighting? {
        try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.id == id })).first
    }

    /// Fotos, die auf eine Sichtung verweisen. Im Speicher gefiltert: Prädikate auf Array-Attributen sind in SwiftData unzuverlässig.
    func photos(linkedTo id: UUID) throws -> [PhotoItem] {
        try fetchPhotos(context).filter { $0.sightingIds.contains(id) }
    }

    // MARK: Korrektur aus der Liste (ganze Sichtung)

    /// Ganze Sichtung umbenennen. Bei sensibler Art werden Sichtung und alle verknüpften Fotos auf das 10-km-Raster gesetzt.
    func rename(_ s: Sighting, to name: String, key: String?) throws {
        do {
            let old = s.name
            s.name = name; s.key = key
            try protect(s, renamedFrom: old)
            try saveContext(context)
        } catch { context.rollback(); throw error }
    }

    /// Fehlalarm: Sichtung entfernen (verknüpfte Fotos bleiben in der Galerie)
    func remove(_ s: Sighting) throws {
        context.delete(s)
        do { try saveContext(context) }
        catch { context.rollback(); throw error }
    }

    // MARK: Korrektur per Tipp auf einen Live-Rahmen

    /// Wendet die Korrektur eines Live-Rahmens an, ohne eine zweite Sichtung für dasselbe Tier anzulegen.
    /// - Parameters:
    ///   - existingId: Sichtung, die der Track schon geloggt hat (oder nil)
    ///   - log: legt eine neue Sichtung an (Name und Schlüssel der Korrektur) und liefert ihre ID
    /// - Returns: die Sichtung, die jetzt zum Track gehört (nil, wenn keine)
    @discardableResult
    func applyTrackCorrection(existingId: UUID?, name: String, key: String?, isNone: Bool, isOther: Bool,
                              log: () -> UUID?) throws -> UUID? {
        let existing = try existingId.map { try sighting(id: $0) } ?? nil
        let action = CorrectionAction.plan(existing: existing?.id, existingCount: existing?.n ?? 0, isNone: isNone, isOther: isOther)
        do {
            switch action {
            case .nothing:
                return nil
            case .logNew:
                guard let id = log() else { throw StoreError.newSightingFailed }
                return id
            case .rename:
                guard let s = existing else { return nil }
                let old = s.name
                s.name = name; s.key = key
                try protect(s, renamedFrom: old)
                try saveContext(context)
                return s.id
            case .remove:
                if let s = existing { context.delete(s) }
                try saveContext(context)
                return nil
            case .decrement:
                if let s = existing { s.n = max(1, s.n - 1) }
                try saveContext(context)
                return nil
            case .split:
                guard let s = existing else {
                    guard let id = log() else { throw StoreError.newSightingFailed }
                    return id
                }
                s.n = max(1, s.n - 1)
                // Eine sensible neue Art schützt auch die Fotos der bisherigen Sammelsichtung.
                if isSensitive(name) { try photos(linkedTo: s.id).forEach { coarsen($0) } }
                // log() speichert die neue und die veränderte alte Sichtung in einem Commit.
                guard let id = log() else { throw StoreError.newSightingFailed }
                return id
            }
        } catch { context.rollback(); throw error }
    }

    // MARK: Artenschutz

    /// Sichtung und verknüpfte Fotos schützen, wenn die (neue) Art sensibel ist; Artnamen der Fotos nachführen
    func protect(_ s: Sighting, renamedFrom old: String?) throws {
        if let p = LocationProtection.protectedPosition(lat: s.lat, lon: s.lon, coarse: s.coarse, sensitive: isSensitive(s.name)), p.coarse, !s.coarse {
            s.lat = p.lat; s.lon = p.lon; s.acc = 10000; s.coarse = true
        }
        for photo in try photos(linkedTo: s.id) {
            if let old, old != s.name { photo.species = LocationProtection.renamedSpecies(photo.species, from: old, to: s.name) }
            protect(photo)
        }
    }

    /// Foto auf das Raster setzen, sobald irgendeine Art darin (Artenliste oder Rahmen) sensibel ist
    func protect(_ photo: PhotoItem) {
        let names = photo.species.map { $0 as String? } + photo.dets.map { $0.name }
        if LocationProtection.containsSensitive(names, isSensitive: isSensitive) { coarsen(photo) }
    }

    /// Foto unabhängig von seinen Artnamen auf das Raster setzen (einmal; schon vergröberte bleiben unverändert)
    func coarsen(_ photo: PhotoItem) {
        guard let p = LocationProtection.protectedPosition(lat: photo.lat, lon: photo.lon, coarse: photo.coarse, sensitive: true), !photo.coarse else { return }
        photo.lat = p.lat; photo.lon = p.lon; photo.coarse = true
    }
}
