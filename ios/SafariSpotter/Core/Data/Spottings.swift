import Foundation

/// Das Album wird aus der aktuellen Sichtungshistorie berechnet. Es besitzt keine eigene Datenbank.
struct Spottings {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let habitats: [AnimalHabitat]
        let sightings: [Sighting]
        var discovered: Bool { !sightings.isEmpty }
        var firstFound: Date? { sightings.last?.t }
    }

    let entries: [Entry]
    var discoveredCount: Int { entries.filter(\.discovered).count }
    var habitatCount: Int { Set(entries.filter(\.discovered).flatMap(\.habitats)).count }

    init(sightings: [Sighting], catalog: SpeciesCatalog) {
        let classes = Dictionary(grouping: catalog.shownClasses, by: Self.identity)
        let groups = Dictionary(grouping: catalog.shownClasses.filter { $0.group != nil }) { $0.group ?? "" }
        let names = Dictionary(grouping: catalog.shownClasses) { Self.normalized($0.name) }
        let groupNames = Dictionary(grouping: groups.keys) { Self.normalized($0) }
        let found = sightings.reduce(into: [String: [Sighting]]()) { result, sighting in
            let candidates: [SpeciesClass]
            if let key = sighting.key, key.hasPrefix("group:") {
                candidates = groups[String(key.dropFirst("group:".count))] ?? []
            } else if let key = sighting.key, let species = catalog.cls(key: key) {
                candidates = species.negative ? [] : [species]
            } else {
                let name = Self.normalized(sighting.name)
                candidates = names[name] ?? (groupNames[name] ?? []).flatMap { groups[$0] ?? [] }
            }
            let identities = Set(candidates.map(Self.identity))
            if identities.count == 1, let identity = identities.first {
                result[identity, default: []].append(sighting)
            }
        }
        entries = classes.map { identity, species in
            let orderedSightings = (found[identity] ?? []).sorted {
                $0.t == $1.t ? $0.id.uuidString < $1.id.uuidString : $0.t > $1.t
            }
            let habitats = Set(species.flatMap { catalog.habitats(for: $0.key) })
            let name = species.count > 1 ? (species.first?.group ?? species[0].name) : species[0].name
            return Entry(id: identity, name: name, habitats: AnimalHabitat.allCases.filter(habitats.contains),
                         sightings: orderedSightings)
        }.sorted {
            if $0.discovered != $1.discovered { return $0.discovered }
            if $0.discovered, $0.sightings[0].t != $1.sightings[0].t { return $0.sightings[0].t > $1.sightings[0].t }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func identity(_ species: SpeciesClass) -> String {
        guard let latin = species.latin, !latin.isEmpty else { return species.key }
        return latin
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_CH"))
    }
}
