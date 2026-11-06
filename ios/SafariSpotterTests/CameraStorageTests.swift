import XCTest
import SwiftData
@testable import SafariSpotter

/// Ein Commit-Fehler darf weder als gespeicherte Sichtung gelten noch einen Track dauerhaft sperren.
final class CameraStorageTests: StoreTestCase {
    private enum SimulatedFailure: Error { case noStorage }

    func testNewSightingSaveFailureCanBeRetried() {
        let camera = CameraController()
        camera.attach(context: context)
        camera.saveContext = { _ in throw SimulatedFailure.noStorage }

        let failed = camera.log(name: "Impala", key: "impala", thumb: nil, src: "manual", image: nil, size: .zero)
        XCTAssertNil(failed)
        XCTAssertTrue(allSightings().isEmpty)
        XCTAssertTrue(camera.lastError?.contains("nicht gespeichert") == true)

        camera.saveContext = { try $0.save() }
        let saved = camera.log(name: "Impala", key: "impala", thumb: nil, src: "manual", image: nil, size: .zero)
        XCTAssertNotNil(saved)
        XCTAssertEqual(allSightings().count, 1)
    }

    func testFailedMergeRestoresCountAndCanBeRetried() {
        let camera = CameraController()
        camera.attach(context: context)
        let id = camera.log(name: "Impala", key: "impala", thumb: nil, src: "manual", image: nil, size: .zero)
        XCTAssertNotNil(id)

        camera.saveContext = { _ in throw SimulatedFailure.noStorage }
        XCTAssertNil(camera.log(name: "Impala", key: "impala", thumb: nil, src: "manual", image: nil, size: .zero))
        XCTAssertEqual(allSightings().first?.n, 1)

        camera.saveContext = { try $0.save() }
        XCTAssertEqual(camera.log(name: "Impala", key: "impala", thumb: nil, src: "manual", image: nil, size: .zero), id)
        XCTAssertEqual(allSightings().first?.n, 2)
    }
}
