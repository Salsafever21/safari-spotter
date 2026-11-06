import XCTest
import SwiftData
@testable import SafariSpotter

/// Beim fehlgeschlagenen SwiftData-Speichern darf die laufende Fahrt nicht verschwinden.
final class DrivePersistenceTests: StoreTestCase {
    func testPreparedDriveKeepsRouteUntilCommit() throws {
        let recorder = DriveRecorder()
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
        let recorder = DriveRecorder()
        recorder.active = true
        recorder.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.points = [TrackPoint(t: 1_700_000_000, lat: .nan, lon: 31.5, spd: 4, alt: nil)]

        XCTAssertThrowsError(try recorder.preparedDrive(sightingsCount: 0))
        XCTAssertTrue(recorder.active)
        XCTAssertEqual(recorder.points.count, 1)
    }

    func testCompletedDriveReconcilesStaleActiveState() throws {
        let recorder = DriveRecorder()
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
}
