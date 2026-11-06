import XCTest
@testable import SafariSpotter

final class SightingHistoryTests: StoreTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return value
    }
    private let locale = Locale(identifier: "de_CH")
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func sighting(_ name: String, at time: Date, n: Int = 1) -> Sighting {
        let value = addSighting(name, n: n); value.t = time; return value
    }

    func testSpringTimeChangeUses23HourDayAndExcludesNextMidnight() {
        let start = date("2026-03-28T23:00:00Z"), end = date("2026-03-29T22:00:00Z")
        let before = sighting("Leopard", at: start.addingTimeInterval(-1))
        let first = sighting("Elefant", at: start)
        let last = sighting("Impala", at: end.addingTimeInterval(-1))
        let after = sighting("Zebra", at: end)
        let filter = SightingHistoryFilter(scope: .today)
        let selected = filter.apply(to: [before, first, last, after], now: start.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(selected.map(\.id), [last.id, first.id])
        XCTAssertEqual(allSightings().count, 4)
        XCTAssertEqual(first.t, start)
    }

    func testAutumnTimeChangeIncludesBothRepeatedHours() {
        let start = date("2026-10-24T22:00:00Z"), end = date("2026-10-25T23:00:00Z")
        let first = sighting("Elefant", at: date("2026-10-25T00:30:00Z"))
        let second = sighting("Leopard", at: date("2026-10-25T01:30:00Z"))
        let next = sighting("Impala", at: end)
        let filter = SightingHistoryFilter(scope: .day, selectedDay: start)
        XCTAssertEqual(filter.apply(to: [first, second, next], calendar: calendar).map(\.id), [second.id, first.id])
    }

    func testSpeciesSearchIgnoresCaseAndUmlautsWithoutChangingRecords() {
        let lion = sighting("Löwe (männlich)", at: .now)
        let leopard = sighting("Leopard", at: .now)
        var filter = SightingHistoryFilter(query: "  LOWE  ")
        XCTAssertEqual(filter.apply(to: [lion, leopard], locale: locale).map(\.id), [lion.id])
        filter.query = ""
        XCTAssertEqual(filter.apply(to: [lion, leopard]).count, 2)
        XCTAssertEqual(lion.name, "Löwe (männlich)")
    }

    func testDayGroupsAndSharedSummaryUseActualSelectionDates() {
        let older = sighting("Elefant", at: date("2023-11-14T12:00:00Z"), n: 2)
        let newer = sighting("Leopard", at: date("2023-11-15T12:00:00Z"))
        let source = [older, newer]
        let groups = SightingHistoryFilter.days(source, calendar: calendar)
        XCTAssertEqual(groups.map { $0.sightings[0].id }, [newer.id, older.id])
        let summary = SightingHistoryFilter().shareText(sightings: source, now: date("2026-11-06T12:00:00Z"), calendar: calendar, locale: locale)
        XCTAssertTrue(summary.contains("14.11.2023 bis 15.11.2023"))
        XCTAssertFalse(summary.contains("06.11.2026"))
        XCTAssertTrue(summary.contains("3 Tiere, 2 Arten"))
        let filtered = SightingHistoryFilter(query: "elefant").shareText(sightings: source, calendar: calendar, locale: locale)
        XCTAssertTrue(filtered.contains("2 Tiere, 1 Art"))
        XCTAssertFalse(filtered.contains("Leopard"))
    }

    func testFilteredCSVStillUsesProtectionFromOutsideSelectedDay() {
        let rhino = sighting("Spitzmaulnashorn", at: date("2026-11-05T22:59:00Z"))
        let impala = sighting("Impala", at: date("2026-11-05T23:01:00Z"))
        let filter = SightingHistoryFilter(scope: .day, selectedDay: impala.t)
        let all = [rhino, impala]
        let selected = filter.apply(to: all, calendar: calendar)
        XCTAssertEqual(selected.map(\.id), [impala.id])
        let csv = Exporters.csv(sightings: selected, catalog: catalog, privacySightings: all)
        XCTAssertFalse(csv.contains("Spitzmaulnashorn"))
        XCTAssertTrue(csv.contains("(gerundet);Impala"))
        XCTAssertFalse(csv.contains(String(format: "%.5f", exact.lat)))
    }

    func testCSVPreservesSeparatorsQuotesAndNewlinesInsideOneCell() {
        let name = "Zebra; \"Savanne\"\nHerde"
        let item = sighting(name, at: .now)
        let rows = parseCSV(Exporters.csv(sightings: [item], catalog: catalog))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].count, 7)
        XCTAssertEqual(rows[1][2], name)
        XCTAssertEqual(rows[1][4], String(format: "%.5f", exact.lat))
        item.name = "=HYPERLINK(\"example\")"
        XCTAssertTrue(parseCSV(Exporters.csv(sightings: [item], catalog: catalog))[1][2].hasPrefix("'="))
    }

    func testShareFilesAreIndependentAndCleanupKeepsCurrentAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TextShareFile.create("old selection", kind: .sightings, extension: "csv", directory: directory)
        let second = try TextShareFile.create("new selection", kind: .sightings, extension: "csv", directory: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "old selection")
        let unrelated = directory.appendingPathComponent("personal.csv")
        try Data("keep".utf8).write(to: unrelated)
        for file in [first, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
        }
        try TextShareFile.removeStale(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertThrowsError(try TextShareFile.create("cannot write", kind: .sightings, extension: "csv", directory: unrelated))
    }

    /// Kleiner unabhängiger Leser: validiert, dass Trennzeichen und Zeilenumbrüche im Feld bleiben.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if character == ";" && !quoted { row.append(field); field = "" }
            else if character == "\n" && !quoted { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(character) }
            index += 1
        }
        row.append(field); rows.append(row)
        return rows
    }
}
