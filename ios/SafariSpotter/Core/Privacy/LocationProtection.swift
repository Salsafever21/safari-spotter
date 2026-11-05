import Foundation

/// Artenschutz-Regeln für Standorte als reine Funktionen (ohne SwiftData und iOS-SDK), damit `ios/Tools/unit-check` sie
/// auch auf Linux prüfen kann. Die Speicherpfade (`SightingStore`) und der Export (`PhotoExporter`) rufen sie auf.
enum LocationProtection {
    /// Kommt eine sensible Art vor (Klassenname wie "Breitmaulnashorn" oder Sammelname wie "Nashorn")?
    static func containsSensitive(_ names: [String?], isSensitive: (String) -> Bool) -> Bool {
        names.contains { name in name.map(isSensitive) ?? false }
    }

    /// Position zum Speichern oder Weitergeben.
    /// - Bereits vergröberte Positionen bleiben unverändert. `Position.coarsen` ist beim Längengrad nicht idempotent
    ///   (die Zellbreite hängt vom Breitengrad ab), darum wird nie ein zweites Mal vergröbert.
    /// - Sensible Positionen kommen auf die Mitte der 10-km-Zelle.
    /// - Ohne Koordinate gibt es keine Position.
    static func protectedPosition(lat: Double?, lon: Double?, coarse: Bool, sensitive: Bool) -> (lat: Double, lon: Double, coarse: Bool)? {
        guard let lat, let lon else { return nil }
        if coarse { return (lat, lon, true) }
        if sensitive {
            let c = Position.coarsen(lat: lat, lon: lon)
            return (c.lat, c.lon, true)
        }
        return (lat, lon, false)
    }

    /// Artnamen eines Fotos, nachdem eine verknüpfte Sichtung von `old` auf `new` umbenannt wurde (Reihenfolge bleibt, keine Duplikate)
    static func renamedSpecies(_ species: [String], from old: String, to new: String) -> [String] {
        var out = species.map { $0 == old ? new : $0 }
        if !out.contains(new) { out.append(new) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

/// Was eine Korrektur per Tipp auf einen Live-Rahmen mit den Sichtungen macht. Grundregel wie in app.js (bestehende Sichtung
/// umbenennen statt eine zweite anlegen). Gehört der Rahmen zu einer zusammengefassten Sichtung (n > 1), wird nur dieses eine
/// Tier abgespalten, die übrigen behalten ihren Namen.
enum CorrectionAction: Equatable {
    case nothing           // keine Sichtung und keine anzulegen ("Kein Tier" / "Anderes Tier" ohne Eintrag)
    case logNew            // noch keine Sichtung: eine neue anlegen
    case rename(UUID)      // Sichtung mit n ≤ 1 umbenennen
    case remove(UUID)      // Sichtung mit n ≤ 1 war ein Fehlalarm
    case decrement(UUID)   // n > 1, das Tier war keines oder kein Safari-Tier: Anzahl um 1 senken
    case split(UUID)       // n > 1, andere Art: Anzahl um 1 senken und das Tier neu eintragen

    static func plan(existing: UUID?, existingCount: Int, isNone: Bool, isOther: Bool) -> CorrectionAction {
        guard let id = existing else { return isNone || isOther ? .nothing : .logNew }
        if existingCount > 1 { return isNone || isOther ? .decrement(id) : .split(id) }
        return isNone ? .remove(id) : .rename(id)
    }
}
