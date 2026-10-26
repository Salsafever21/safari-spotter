import Foundation
import CoreLocation

/// Eine Modellklasse (Art), wie in species-labels.json (Reihenfolge = Ausgabe des Artenmodells)
struct SpeciesClass: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let group: String?
    let negative: Bool
    let sensitive: Bool
    let latin: String?
    var id: String { key }
}

/// Steckbrief aus species-info.json
struct SpeciesInfo: Codable {
    let latin: String?
    let en: String?
    let big5: Bool?
    let sensitive: Bool?
    let size: String?
    let weight: String?
    let id: String?
    let confuse: String?
    let habits: String?
    let status: String?
}

/// Region mit Bounding-Box und unplausiblen Arten (regions.json)
struct Region: Codable, Identifiable {
    let key: String
    let name: String
    let bbox: [Double]       // [südl. Breite, westl. Länge, nördl. Breite, östl. Länge]
    let unlikely: [String]
    var id: String { key }
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= bbox[0] && c.longitude >= bbox[1] && c.latitude <= bbox[2] && c.longitude <= bbox[3]
    }
}

struct RegionsFile: Codable { let factor: Double; let regions: [Region] }
struct LabelsFile: Codable { let version: String?; let trained: String?; let valTop1: Double?; let classes: [SpeciesClass] }

/// Artenwissen der App: Klassen, Steckbriefe, Regionen. Entspricht classes.json + species-info.json + regions.json der Web-App.
final class SpeciesCatalog: ObservableObject {
    static let shared = SpeciesCatalog()
    let classes: [SpeciesClass]
    let info: [String: SpeciesInfo]
    let regions: [Region]
    let priorFactor: Double
    let modelVersion: String
    private let byKey: [String: SpeciesClass]
    private let byName: [String: SpeciesClass]

    init() {
        func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let labels = load("species-labels", as: LabelsFile.self)
        classes = labels?.classes ?? []
        modelVersion = labels?.version ?? "?"
        // species-info.json hat einen "_comment"-Schlüssel; den beim Dekodieren überspringen
        if let url = Bundle.main.url(forResource: "species-info", withExtension: "json"), let data = try? Data(contentsOf: url),
           var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw.removeValue(forKey: "_comment")
            let clean = try? JSONSerialization.data(withJSONObject: raw)
            info = (clean.flatMap { try? JSONDecoder().decode([String: SpeciesInfo].self, from: $0) }) ?? [:]
        } else { info = [:] }
        let r = load("regions", as: RegionsFile.self)
        regions = r?.regions ?? []
        priorFactor = r?.factor ?? 0.25
        byKey = Dictionary(uniqueKeysWithValues: classes.map { ($0.key, $0) })
        byName = Dictionary(classes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func cls(key: String) -> SpeciesClass? { byKey[key] }
    func cls(name: String) -> SpeciesClass? { byName[name] }
    var shownClasses: [SpeciesClass] { classes.filter { !$0.negative } }

    /// Artenschutz: Nashörner (Klasse oder Sammelname)
    func isSensitive(name: String) -> Bool {
        if let c = byName[name], c.sensitive { return true }
        return classes.contains { $0.sensitive && $0.group == name }
    }

    func region(for coordinate: CLLocationCoordinate2D?) -> Region? {
        guard let c = coordinate else { return nil }
        return regions.first { $0.contains(c) }
    }

    /// Dämpft Arten, die in der Region nicht vorkommen (nie auf null, damit klare Bilder gewinnen)
    func applyPrior(_ probs: [Double], region: Region?) -> [Double] {
        guard let r = region else { return probs }
        let bad = Set(r.unlikely)
        var out = probs
        for (i, c) in classes.enumerated() where bad.contains(c.key) { out[i] *= priorFactor }
        let sum = out.reduce(0, +)
        return sum > 0 ? out.map { $0 / sum } : probs
    }
}

/// Entscheidung aus den (geglätteten) Wahrscheinlichkeiten, identisch zur Web-App (decideSpecies)
struct SpeciesDecision {
    var name: String?
    var key: String?
    var confidence: Double
    var sure: Bool
    var other: Bool

    static func decide(_ probs: [Double], catalog: SpeciesCatalog) -> SpeciesDecision {
        let cls = catalog.classes
        let order = probs.enumerated().sorted { $0.element > $1.element }
        guard order.count >= 2 else { return SpeciesDecision(name: nil, key: nil, confidence: 0, sure: false, other: false) }
        let (i1, p1) = (order[0].offset, order[0].element)
        let (i2, p2) = (order[1].offset, order[1].element)
        let c1 = cls[i1], c2 = cls[i2]
        if c1.negative { return SpeciesDecision(name: "Anderes Tier", key: c1.key, confidence: p1, sure: false, other: true) }
        if let g = c1.group, c2.group == g, p1 - p2 < 0.3 {
            return SpeciesDecision(name: g, key: "group:" + g, confidence: p1 + p2, sure: p1 + p2 >= 0.5, other: false)
        }
        if p1 < 0.35 { return SpeciesDecision(name: nil, key: nil, confidence: p1, sure: false, other: false) }
        return SpeciesDecision(name: c1.name, key: c1.key, confidence: p1, sure: p1 >= 0.5, other: false)
    }
}
