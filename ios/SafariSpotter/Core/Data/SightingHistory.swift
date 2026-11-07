import Foundation

enum SightingDateScope: String, CaseIterable, Identifiable {
    case all = "Alle Tage", today = "Heute", day = "Tag wählen"
    var id: String { rawValue }
}

struct SightingDay: Identifiable {
    let date: Date
    let sightings: [Sighting]
    var id: Date { date }
}

/// Reine Ansichtsauswahl. Ändert keine Sichtung und verwendet lokale Kalendertage statt fester 24-Stunden-Fenster.
struct SightingHistoryFilter {
    var scope: SightingDateScope = .all
    var selectedDay: Date = .now
    var query = ""

    func apply(to sightings: [Sighting], now: Date = .now, calendar: Calendar = .current,
               locale: Locale = .current) -> [Sighting] {
        let interval: DateInterval?
        switch scope {
        case .all: interval = nil
        case .today: interval = calendar.dateInterval(of: .day, for: now)
        case .day: interval = calendar.dateInterval(of: .day, for: selectedDay)
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return sightings.filter { sighting in
            // Ende exklusiv, damit Mitternacht nur zum neuen Tag gehört.
            let inDay = interval.map { sighting.t >= $0.start && sighting.t < $0.end } ?? true
            return inDay && (search.isEmpty || sighting.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).contains(search))
        }.sorted { $0.t == $1.t ? $0.id.uuidString < $1.id.uuidString : $0.t > $1.t }
    }

    func title(now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch scope {
        case .all: return "Alle Tage"
        case .today: return "Heute · " + Self.dateLabel(now, calendar: calendar, locale: locale)
        case .day: return Self.dateLabel(selectedDay, calendar: calendar, locale: locale)
        }
    }

    static func days(_ sightings: [Sighting], calendar: Calendar = .current) -> [SightingDay] {
        Dictionary(grouping: sightings) { calendar.startOfDay(for: $0.t) }
            .map { SightingDay(date: $0.key, sightings: $0.value.sorted { $0.t > $1.t }) }
            .sorted { $0.date > $1.date }
    }

    static func counts(_ sightings: [Sighting]) -> [(name: String, count: Int)] {
        Dictionary(sightings.map { ($0.name, $0.n) }, uniquingKeysWith: +)
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.count > $1.count }
    }

    func shareText(sightings: [Sighting], now: Date = .now, calendar: Calendar = .current,
                   locale: Locale = .current) -> String {
        let selected = apply(to: sightings, now: now, calendar: calendar, locale: locale)
        let counts = Self.counts(selected)
        let total = counts.reduce(0) { $0 + $1.count }
        var period = title(now: now, calendar: calendar, locale: locale)
        if scope == .all, let first = selected.last?.t, let last = selected.first?.t {
            let from = Self.dateLabel(first, calendar: calendar, locale: locale)
            let to = Self.dateLabel(last, calendar: calendar, locale: locale)
            period += " · " + (from == to ? from : from + " bis " + to)
        }
        var lines = ["Safari · \(period)"]
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { lines.append("Artfilter: " + search) }
        lines.append("\(total) \(total == 1 ? "Tier" : "Tiere"), \(counts.count) \(counts.count == 1 ? "Art" : "Arten")")
        lines += counts.map { "\($0.name) \($0.count)×" }
        return lines.joined(separator: "\n")
    }

    static func dateLabel(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }
}
