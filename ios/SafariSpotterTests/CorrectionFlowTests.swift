import XCTest
@testable import SafariSpotter

/// Korrektur per Tipp auf einen Live-Rahmen: nie zwei Sichtungen für dasselbe Tier (Befund D1), bei zusammengefassten
/// Sichtungen wird genau ein Tier abgespalten
final class CorrectionFlowTests: StoreTestCase {
    private var logged = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        logged = 0
    }

    /// Ersatz für CameraController.logOnMain: zählt, wie oft eine neue Sichtung angelegt wird
    private func logNew(_ name: String) -> () -> UUID? {
        { self.logged += 1; return self.addSighting(name).id }
    }

    private var animals: Int { allSightings().reduce(0) { $0 + $1.n } }

    func testRenamesExistingSightingInsteadOfAddingOne() throws {
        let s = addSighting("Impala")
        let id = try store.applyTrackCorrection(existingId: s.id, name: "Grosser Kudu", key: "kudu", isNone: false, isOther: false, log: logNew("Grosser Kudu"))
        XCTAssertEqual(id, s.id); XCTAssertEqual(logged, 0)
        XCTAssertEqual(allSightings().count, 1); XCTAssertEqual(s.name, "Grosser Kudu")
    }

    func testRepeatedCorrectionStaysOneSighting() throws {
        let s = addSighting("Impala")
        let first = try store.applyTrackCorrection(existingId: s.id, name: "Grosser Kudu", key: "kudu", isNone: false, isOther: false, log: logNew("Grosser Kudu"))
        _ = try store.applyTrackCorrection(existingId: first, name: "Nyala", key: "nyala", isNone: false, isOther: false, log: logNew("Nyala"))
        XCTAssertEqual(logged, 0); XCTAssertEqual(allSightings().count, 1); XCTAssertEqual(s.name, "Nyala")
    }

    func testSplitsMergedSighting() throws {
        let s = addSighting("Impala", n: 2)
        let id = try store.applyTrackCorrection(existingId: s.id, name: "Grosser Kudu", key: "kudu", isNone: false, isOther: false, log: logNew("Grosser Kudu"))
        XCTAssertEqual(logged, 1); XCTAssertNotEqual(id, s.id)
        XCTAssertEqual(s.n, 1); XCTAssertEqual(s.name, "Impala", "die übrigen Tiere behalten ihren Namen")
        XCTAssertEqual(animals, 2, "Gesamtzahl bleibt")
    }

    func testSplitToRhinoCoarsensPhotosOfMergedSighting() throws {
        let s = addSighting("Impala", n: 2)
        let p = addPhoto(species: ["Impala"], sightingIds: [s.id])
        _ = try store.applyTrackCorrection(existingId: s.id, name: "Breitmaulnashorn", key: "breitmaulnashorn", isNone: false, isOther: false, log: logNew("Breitmaulnashorn"))
        XCTAssertTrue(p.coarse, "das Foto kann das Nashorn zeigen")
        XCTAssertFalse(s.coarse, "die verbleibenden Impalas behalten ihren Standort")
    }

    func testLiveRenameToRhinoProtectsSightingAndPhoto() throws {
        let s = addSighting("Elefant")
        let p = addPhoto(species: ["Elefant"], sightingIds: [s.id])
        _ = try store.applyTrackCorrection(existingId: s.id, name: "Spitzmaulnashorn", key: "spitzmaulnashorn", isNone: false, isOther: false, log: logNew("Spitzmaulnashorn"))
        XCTAssertEqual(logged, 0)
        XCTAssertTrue(s.coarse); XCTAssertTrue(p.coarse)
        XCTAssertEqual(s.lon, coarsePosition.lon); XCTAssertEqual(p.lon, coarsePosition.lon)
    }

    func testFalseAlarmRemovesSingleSighting() throws {
        let s = addSighting("Impala")
        XCTAssertNil(try store.applyTrackCorrection(existingId: s.id, name: "Kein Tier", key: "__none", isNone: true, isOther: false, log: logNew("x")))
        XCTAssertEqual(logged, 0); XCTAssertTrue(allSightings().isEmpty)
    }

    func testFalseAlarmInMergedSightingDecrements() throws {
        let s = addSighting("Impala", n: 3)
        _ = try store.applyTrackCorrection(existingId: s.id, name: "Kein Tier", key: "__none", isNone: true, isOther: false, log: logNew("x"))
        XCTAssertEqual(logged, 0); XCTAssertEqual(s.n, 2)
    }

    func testOtherAnimalInMergedSightingDecrements() throws {
        let s = addSighting("Impala", n: 2)
        _ = try store.applyTrackCorrection(existingId: s.id, name: "Anderes Tier", key: "__other", isNone: false, isOther: true, log: logNew("x"))
        XCTAssertEqual(logged, 0); XCTAssertEqual(s.n, 1)
    }

    func testWithoutSightingLogsExactlyOne() throws {
        _ = try store.applyTrackCorrection(existingId: nil, name: "Grosser Kudu", key: "kudu", isNone: false, isOther: false, log: logNew("Grosser Kudu"))
        XCTAssertEqual(logged, 1); XCTAssertEqual(allSightings().count, 1)
    }

    func testWithoutSightingFalseAlarmLogsNothing() throws {
        _ = try store.applyTrackCorrection(existingId: nil, name: "Kein Tier", key: "__none", isNone: true, isOther: false, log: logNew("x"))
        _ = try store.applyTrackCorrection(existingId: nil, name: "Anderes Tier", key: "__other", isNone: false, isOther: true, log: logNew("x"))
        XCTAssertEqual(logged, 0); XCTAssertTrue(allSightings().isEmpty)
    }

    func testDeletedSightingIsTreatedAsNew() throws {
        _ = try store.applyTrackCorrection(existingId: UUID(), name: "Grosser Kudu", key: "kudu", isNone: false, isOther: false, log: logNew("Grosser Kudu"))
        XCTAssertEqual(logged, 1)
    }
}
