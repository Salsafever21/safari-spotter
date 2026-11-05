import Foundation
import SwiftData

/// Schreibzugriffe auf Sichtungen, die Zählung und Artenschutz betreffen. Arbeitet mit dem `ModelContext` der App und wird
/// darum auf dem Main-Thread benutzt (UI, `CameraController` über `DispatchQueue.main`). Löscht nur, wenn die Korrektur
/// ausdrücklich "Kein Tier" sagt, und ändert das Datenmodell nicht.
struct SightingStore {
    let context: ModelContext
    let isSensitive: (String) -> Bool

    init(context: ModelContext, isSensitive: @escaping (String) -> Bool) {
        self.context = context
        self.isSensitive = isSensitive
    }

    init(context: ModelContext, catalog: SpeciesCatalog) {
        self.init(context: context, isSensitive: { catalog.isSensitive(name: $0) })
    }

    func sighting(id: UUID) -> Sighting? {
        try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.id == id })).first
    }

    /// Fotos, die auf eine Sichtung verweisen. Im Speicher gefiltert: Prädikate auf Array-Attributen sind in SwiftData unzuverlässig.
    func photos(linkedTo id: UUID) -> [PhotoItem] {
        ((try? context.fetch(FetchDescriptor<PhotoItem>())) ?? []).filter { $0.sightingIds.contains(id) }
    }

    // MARK: Korrektur aus der Liste (ganze Sichtung)

    /// Ganze Sichtung umbenennen. Bei sensibler Art werden Sichtung und alle verknüpften Fotos auf das 10-km-Raster gesetzt.
    func rename(_ s: Sighting, to name: String, key: String?) {
        let old = s.name
        s.name = name; s.key = key
        protect(s, renamedFrom: old)
        try? context.save()
    }

    /// Fehlalarm: Sichtung entfernen (verknüpfte Fotos bleiben in der Galerie)
    func remove(_ s: Sighting) {
        context.delete(s)
        try? context.save()
    }

    // MARK: Korrektur per Tipp auf einen Live-Rahmen

    /// Wendet die Korrektur eines Live-Rahmens an, ohne eine zweite Sichtung für dasselbe Tier anzulegen.
    /// - Parameters:
    ///   - existingId: Sichtung, die der Track schon geloggt hat (oder nil)
    ///   - log: legt eine neue Sichtung an (Name und Schlüssel der Korrektur) und liefert ihre ID
    /// - Returns: die Sichtung, die jetzt zum Track gehört (nil, wenn keine)
    @discardableResult
    func applyTrackCorrection(existingId: UUID?, name: String, key: String?, isNone: Bool, isOther: Bool, log: () -> UUID?) -> UUID? {
        let existing = existingId.flatMap { sighting(id: $0) }
        let action = CorrectionAction.plan(existing: existing?.id, existingCount: existing?.n ?? 0, isNone: isNone, isOther: isOther)
        defer { try? context.save() }
        switch action {
        case .nothing:
            return nil
        case .logNew:
            return log()
        case .rename:
            guard let s = existing else { return nil }
            let old = s.name
            s.name = name; s.key = key
            protect(s, renamedFrom: old)
            return s.id
        case .remove:
            if let s = existing { context.delete(s) }
            return nil
        case .decrement:
            if let s = existing { s.n = max(1, s.n - 1) }
            return nil
        case .split:
            guard let s = existing else { return log() }
            s.n = max(1, s.n - 1)
            // Die Fotos der Sammelsichtung können das korrigierte Tier zeigen: bei sensibler Art auch sie vergröbern
            if isSensitive(name) { photos(linkedTo: s.id).forEach { coarsen($0) } }
            return log()
        }
    }

    // MARK: Artenschutz

    /// Sichtung und verknüpfte Fotos schützen, wenn die (neue) Art sensibel ist; Artnamen der Fotos nachführen
    func protect(_ s: Sighting, renamedFrom old: String?) {
        if let p = LocationProtection.protectedPosition(lat: s.lat, lon: s.lon, coarse: s.coarse, sensitive: isSensitive(s.name)), p.coarse, !s.coarse {
            s.lat = p.lat; s.lon = p.lon; s.acc = 10000; s.coarse = true
        }
        for photo in photos(linkedTo: s.id) {
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
