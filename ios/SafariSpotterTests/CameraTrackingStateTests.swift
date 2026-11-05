import XCTest
@testable import SafariSpotter

@MainActor
final class CameraTrackingStateTests: XCTestCase {
    func testLateDetectionCannotRestoreStoppedOverlay() {
        let camera = CameraController()
        let frame = CameraController.TrackSnapshot(
            id: 1, box: CGRect(x: 20, y: 30, width: 100, height: 120),
            name: "Elefant", sub: "bestätigt", sure: true, colorIndex: 0)

        camera.setTracking(true)
        let activeGeneration = camera.currentDisplayGeneration
        camera.publishFrame([frame], size: CGSize(width: 1920, height: 1080), elapsed: 0.2,
                            generation: activeGeneration)
        XCTAssertEqual(camera.tracks.count, 1)
        XCTAssertEqual(camera.status, "1 Tier im Bild")

        camera.setTracking(false)
        camera.publishFrame([frame], size: CGSize(width: 1920, height: 1080), elapsed: 0.2,
                            generation: activeGeneration)
        XCTAssertTrue(camera.tracks.isEmpty)
        XCTAssertEqual(camera.status, "Tracken aus")

        camera.setTracking(true)
        camera.publishFrame([frame], size: CGSize(width: 1920, height: 1080), elapsed: 0.2,
                            generation: activeGeneration)
        XCTAssertTrue(camera.tracks.isEmpty, "Ein Ergebnis aus dem vorigen Lauf darf nicht wieder erscheinen")
        XCTAssertEqual(camera.status, "Suche Tiere …")
    }
}
