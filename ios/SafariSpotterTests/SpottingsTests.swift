import XCTest
@testable import SafariSpotter

final class SpottingsTests: StoreTestCase {
    func testOlderSightingsCountBySpeciesAndRecordsRatherThanAnimalQuantity() throws {
        let old = addSighting("  ELEFANT ", n: 12)
        old.t = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = addSighting("Elefant")
        let leopard = addSighting("Leopard")

        let album = Spottings(sightings: allSightings(), catalog: catalog)
        let elephants = try XCTUnwrap(album.entries.first { $0.name == "Elefant" })
        XCTAssertEqual(album.discoveredCount, 2)
        XCTAssertEqual(album.habitatCount, 1)
        XCTAssertEqual(elephants.sightings.map(\.id), [newer.id, old.id])
        XCTAssertEqual(elephants.firstFound, old.t)
        XCTAssertTrue(album.entries.contains { $0.name == leopard.name && $0.discovered })
        XCTAssertEqual(allSightings().count, 3)
    }

    func testLionLabelsResolveToOneSpeciesAndAmbiguousGroupsStayOpen() throws {
        let lion = addSighting("Löwe (männlich)")
        let lioness = addSighting("Löwin")
        let lionGroup = addSighting("Löwe")
        lionGroup.key = "group:Löwe"
        let rhino = addSighting("Nashorn")
        rhino.key = "group:Nashorn"
        let negative = addSighting("Elefant")
        negative.key = "anderes_rind"

        let album = Spottings(sightings: allSightings(), catalog: catalog)
        let entry = try XCTUnwrap(album.entries.first { $0.name == "Löwe" })
        XCTAssertEqual(album.discoveredCount, 1)
        XCTAssertEqual(Set(entry.sightings.map(\.id)), Set([lion.id, lioness.id, lionGroup.id]))
    }

    func testCorrectionAndDeletionRecalculateTheAlbumAndHabitats() throws {
        let bird = addSighting("Gaukler")
        let hippo = addSighting("Flusspferd")
        XCTAssertEqual(Spottings(sightings: allSightings(), catalog: catalog).habitatCount, 3)

        bird.name = "Leopard"
        bird.key = "leopard"
        try context.save()
        let corrected = Spottings(sightings: allSightings(), catalog: catalog)
        XCTAssertEqual(corrected.habitatCount, 2)
        XCTAssertFalse(corrected.entries.contains { $0.name == "Gaukler" && $0.discovered })

        try store.remove(hippo)
        let afterDeletion = Spottings(sightings: allSightings(), catalog: catalog)
        XCTAssertEqual(afterDeletion.habitatCount, 1)
        XCTAssertEqual(afterDeletion.entries.filter(\.discovered).map(\.name), ["Leopard"])
    }
}
