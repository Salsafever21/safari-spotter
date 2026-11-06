import XCTest
@testable import SafariSpotter

final class DriveHistoryTests: StoreTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sighting(_ name: String, at offset: TimeInterval) -> Sighting {
        let item = addSighting(name)
        item.t = start.addingTimeInterval(offset)
        return item
    }

    private func point(_ offset: TimeInterval, latitude: Double) -> TrackPoint {
        TrackPoint(t: start.timeIntervalSince1970 + offset, lat: latitude, lon: 31, spd: 4, alt: nil)
    }

    func testWindowKeepsOnlySelectedDriveContentAndOrdersRoute() throws {
        let window = try DriveWindow(start: start, end: start.addingTimeInterval(3600))
        let before = sighting("Leopard", at: -1)
        let first = sighting("Elefant", at: 0)
        let last = sighting("Impala", at: 3600)
        let after = sighting("Gepard", at: 3601)
        XCTAssertEqual(window.sightings(from: [before, first, last, after]).map(\.id), [first.id, last.id])
        let insidePhoto = addPhoto(species: ["Elefant"], sightingIds: [first.id])
        insidePhoto.t = start.addingTimeInterval(100)
        let outsidePhoto = addPhoto(species: ["Leopard"], sightingIds: [before.id])
        outsidePhoto.t = start.addingTimeInterval(-100)
        XCTAssertEqual(window.photos(from: [insidePhoto, outsidePhoto]).map(\.id), [insidePhoto.id])
        let route = window.points(from: [point(200, latitude: -24), point(-1, latitude: -25),
                                        point(100, latitude: -26), point(3601, latitude: -27)])
        XCTAssertEqual(route.map(\.lat), [-26, -24])
        XCTAssertThrowsError(try DriveWindow(start: start, end: start.addingTimeInterval(-1)))
    }

    func testDriveExportsOnlyItsSightingsAndRoute() throws {
        let inside = sighting("Elefant", at: 100)
        let outside = sighting("Leopard", at: 4000)
        let drive = try Drive(startedAt: start, endedAt: start.addingTimeInterval(3600), dist: 1000,
                              points: [point(-1, latitude: -20), point(100, latitude: -21),
                                       point(3601, latitude: -22)], sightings: 1)
        let gpx = try DriveHistoryExport.gpx(drive: drive, sightings: [outside, inside], catalog: catalog)
        XCTAssertTrue(gpx.contains("<name>Elefant</name>"))
        XCTAssertFalse(gpx.contains("Leopard"))
        XCTAssertTrue(gpx.contains("<trkpt lat=\"-21.0\""))
        XCTAssertFalse(gpx.contains("<trkpt lat=\"-20.0\""))
        XCTAssertFalse(gpx.contains("<trkpt lat=\"-22.0\""))
        let csv = try DriveHistoryExport.csv(drive: drive, sightings: [outside, inside], catalog: catalog)
        XCTAssertTrue(csv.contains("Elefant"))
        XCTAssertFalse(csv.contains("Leopard"))
    }

    func testRhinosOutsideDriveStillProtectNearbyRouteWithoutBecomingWaypoints() throws {
        let before = sighting("Spitzmaulnashorn", at: -10)
        let after = sighting("Breitmaulnashorn", at: 3610)
        let drive = try Drive(startedAt: start, endedAt: start.addingTimeInterval(3600), dist: 1000,
                              points: [point(5, latitude: -20), point(1800, latitude: -21),
                                       point(3595, latitude: -22)], sightings: 0)
        let gpx = try DriveHistoryExport.gpx(drive: drive, sightings: [before, after], catalog: catalog)
        XCTAssertFalse(gpx.contains("<wpt"))
        XCTAssertFalse(gpx.contains("<trkpt lat=\"-20.0\""))
        XCTAssertTrue(gpx.contains("<trkpt lat=\"-21.0\""))
        XCTAssertFalse(gpx.contains("<trkpt lat=\"-22.0\""))
    }

    func testLegacyExactRhinoIsCoarsenedAtExportWithoutMovingSavedData() throws {
        let rhino = sighting("Spitzmaulnashorn", at: 100)
        let expected = coarsePosition
        let gpx = Exporters.gpx(points: [], sightings: [rhino], catalog: catalog, version: "test")
        XCTAssertTrue(gpx.contains("lat=\"\(String(format: "%.3f", expected.lat))\""))
        XCTAssertTrue(gpx.contains("lon=\"\(String(format: "%.3f", expected.lon))\""))
        let csv = Exporters.csv(sightings: [rhino], catalog: catalog)
        XCTAssertTrue(csv.contains(";\(String(format: "%.2f", expected.lat));\(String(format: "%.2f", expected.lon));"))
        XCTAssertEqual(rhino.lat, exact.lat)
        XCTAssertFalse(rhino.coarse)
    }

    func testCorruptRouteStopsExportAndFilesAreIndependentSnapshots() throws {
        let drive = try Drive(startedAt: start, endedAt: start.addingTimeInterval(10), dist: 0, points: [], sightings: 0)
        drive.pointsJSON = Data("corrupt".utf8)
        XCTAssertThrowsError(try DriveHistoryExport.gpx(drive: drive, sightings: [], catalog: catalog))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DriveHistoryExport.createFile("first", extension: "gpx", directory: directory)
        let second = try DriveHistoryExport.createFile("second", extension: "gpx", directory: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: first.path)
        try DriveHistoryExport.removeStale(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
