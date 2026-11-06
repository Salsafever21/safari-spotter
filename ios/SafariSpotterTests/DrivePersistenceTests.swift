import XCTest
import SwiftData
import CoreLocation
@testable import SafariSpotter

/// Beim fehlgeschlagenen SwiftData-Speichern darf die laufende Fahrt nicht verschwinden.
final class DrivePersistenceTests: StoreTestCase {
    private func makeRecorder() -> (DriveRecorder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drive-test-\(UUID().uuidString).json")
        addTeardownBlock { _ = try? FileManager.default.removeItem(at: url) }
        return (DriveRecorder(stateURL: url), url)
    }

    func testPreparedDriveKeepsRouteUntilCommit() throws {
        let (recorder, _) = makeRecorder()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.active = true
        recorder.startedAt = start
        recorder.points = [TrackPoint(t: start.timeIntervalSince1970, lat: -24.9, lon: 31.5, spd: 4, alt: 300)]
        recorder.dist = 123

        let prepared = try XCTUnwrap(try recorder.preparedDrive(sightingsCount: 2))
        XCTAssertTrue(recorder.active, "vor einem erfolgreichen Commit bleibt die Fahrt aktiv")
        XCTAssertEqual(recorder.points.count, 1)

        context.insert(prepared)
        try context.save()
        recorder.finishDrive()
        XCTAssertFalse(recorder.active)
        XCTAssertTrue(recorder.points.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Drive>()).count, 1)
    }

    func testUnencodablePointKeepsDriveActive() throws {
        let (recorder, _) = makeRecorder()
        recorder.active = true
        recorder.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.points = [TrackPoint(t: 1_700_000_000, lat: .nan, lon: 31.5, spd: 4, alt: nil)]

        XCTAssertThrowsError(try recorder.preparedDrive(sightingsCount: 0))
        XCTAssertTrue(recorder.active)
        XCTAssertEqual(recorder.points.count, 1)
    }

    func testCompletedDriveReconcilesStaleActiveState() throws {
        let (recorder, _) = makeRecorder()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.active = true
        recorder.startedAt = start
        recorder.points = [TrackPoint(t: start.timeIntervalSince1970, lat: -24.9, lon: 31.5, spd: 4, alt: 300)]

        recorder.reconcileCompletedDrive(startedAt: start.addingTimeInterval(10))
        XCTAssertTrue(recorder.active)
        recorder.reconcileCompletedDrive(startedAt: start)
        XCTAssertFalse(recorder.active)
        XCTAssertTrue(recorder.points.isEmpty)
    }

    func testBatchedLocationsKeepEveryNewPointInTimeOrder() throws {
        let (recorder, stateURL) = makeRecorder()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.active = true
        recorder.startedAt = start
        recorder.points = []
        recorder.dist = 0
        func fix(_ seconds: TimeInterval, _ lat: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 31.5), altitude: 300,
                       horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 4,
                       timestamp: start.addingTimeInterval(seconds))
        }
        let beforeStart = fix(-1, -24.9002)
        let first = fix(1, -24.9000)
        let second = fix(2, -24.8998)
        let third = fix(3, -24.8996)
        let manager = CLLocationManager()
        recorder.locationManager(manager, didUpdateLocations: [third, beforeStart, second, first, first])

        XCTAssertEqual(recorder.points.map(\.t), [first.timestamp, second.timestamp, third.timestamp]
            .map(\.timeIntervalSince1970))
        XCTAssertEqual(recorder.lastFix?.timestamp, third.timestamp)
        XCTAssertGreaterThan(recorder.dist, 40)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual((saved["points"] as? [[String: Any]])?.count, 3, "der ganze GPS-Stapel ist sofort gesichert")

        recorder.locationManager(manager, didUpdateLocations: [second])
        XCTAssertEqual(recorder.points.count, 3)
        XCTAssertEqual(recorder.lastFix?.timestamp, third.timestamp)
    }
}
