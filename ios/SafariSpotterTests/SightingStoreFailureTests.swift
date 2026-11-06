import XCTest
import SwiftData
@testable import SafariSpotter

/// Eine fehlgeschlagene Korrektur darf weder Zählung noch geschützte Foto-Position halb ändern.
final class SightingStoreFailureTests: StoreTestCase {
    private enum SimulatedFailure: Error { case unavailable }

    func testCountCannotDeleteSightingOrLinkedPhoto() throws {
        let sighting = addSighting("Elefant")
        let photo = addPhoto(species: ["Elefant"], sightingIds: [sighting.id])
        XCTAssertThrowsError(try store.setCount(0, for: sighting))
        XCTAssertThrowsError(try store.setCount(-1, for: sighting))
        XCTAssertEqual(try store.sighting(id: sighting.id)?.n, 1)
        try store.setCount(3, for: sighting)
        try store.setCount(1, for: sighting)
        XCTAssertEqual(try store.sighting(id: sighting.id)?.n, 1)
        XCTAssertEqual(try store.photos(linkedTo: sighting.id).map(\.id), [photo.id])
    }

    func testFailedCountChangeRollsBackPreviousCount() throws {
        let sighting = addSighting("Impala", n: 2)
        let failing = SightingStore(context: context, catalog: catalog,
                                    saveContext: { _ in throw SimulatedFailure.unavailable })
        XCTAssertThrowsError(try failing.setCount(1, for: sighting))
        XCTAssertEqual(try store.sighting(id: sighting.id)?.n, 2)
    }

    func testExplicitSightingRemovalPreservesPhoto() throws {
        let sighting = addSighting("Leopard")
        let photo = addPhoto(species: ["Leopard"], sightingIds: [sighting.id])
        let id = sighting.id
        try store.remove(sighting)
        XCTAssertNil(try store.sighting(id: id))
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoItem>()).map(\.id), [photo.id])
    }

    func testFailedRenameRollsBackSightingAndPhoto() throws {
        let sighting = addSighting("Elefant")
        let photo = addPhoto(species: ["Elefant"], sightingIds: [sighting.id])
        let failing = SightingStore(context: context, catalog: catalog,
                                    saveContext: { _ in throw SimulatedFailure.unavailable })

        XCTAssertThrowsError(try failing.rename(sighting, to: "Breitmaulnashorn", key: "breitmaulnashorn"))
        XCTAssertEqual(try store.sighting(id: sighting.id)?.name, "Elefant")
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoItem>()).first { $0.id == photo.id })
        XCTAssertEqual(restored.species, ["Elefant"])
        XCTAssertFalse(restored.coarse)
    }

    func testPhotoFetchFailureAbortsSensitiveRename() throws {
        let sighting = addSighting("Elefant")
        let failing = SightingStore(context: context, catalog: catalog,
                                    fetchPhotos: { _ in throw SimulatedFailure.unavailable })

        XCTAssertThrowsError(try failing.rename(sighting, to: "Spitzmaulnashorn", key: "spitzmaulnashorn"))
        XCTAssertEqual(try store.sighting(id: sighting.id)?.name, "Elefant")
        XCTAssertFalse(try XCTUnwrap(store.sighting(id: sighting.id)).coarse)
    }

    func testFailedSplitRestoresCountAndLinkedPhoto() throws {
        let sighting = addSighting("Impala", n: 2)
        let photo = addPhoto(species: ["Impala"], sightingIds: [sighting.id])

        XCTAssertThrowsError(try store.applyTrackCorrection(existingId: sighting.id, name: "Breitmaulnashorn",
                                                               key: "breitmaulnashorn", isNone: false, isOther: false,
                                                               log: { nil }))
        XCTAssertEqual(try store.sighting(id: sighting.id)?.n, 2)
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoItem>()).first { $0.id == photo.id })
        XCTAssertFalse(restored.coarse)
    }
}
