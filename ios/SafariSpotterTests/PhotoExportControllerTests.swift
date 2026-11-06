import XCTest
import SwiftData
@testable import SafariSpotter

final class PhotoExportControllerTests: StoreTestCase {
    private enum Failure: Error { case interrupted }

    @MainActor
    func testRapidStartsDoNotDuplicatePhotosAndEmptyStartDoesNotResetResult() async {
        let first = addPhoto(species: ["Elefant"], sightingIds: [])
        let second = addPhoto(species: ["Leopard"], sightingIds: [])
        var writes: [UUID] = []
        let exporter = PhotoExportController { photo, _, _ in writes.append(photo.id) }
        XCTAssertTrue(exporter.start(photos: [first, first, second], context: context, catalog: catalog))
        XCTAssertTrue(exporter.isRunning, "Der Schutz muss vor dem ersten Task-Wechsel aktiv sein")
        XCTAssertFalse(exporter.start(photos: [first], context: context, catalog: catalog))
        XCTAssertFalse(exporter.retry())
        XCTAssertFalse(exporter.discardFailedJob(), "Ein laufender Auftrag darf nicht freigegeben werden")
        await exporter.waitUntilIdle()
        XCTAssertEqual(writes, [first.id, second.id])
        XCTAssertEqual(exporter.completed, 2)
        XCTAssertEqual(exporter.savedIDs, [first.id, second.id])
        XCTAssertFalse(exporter.isRunning)
        XCTAssertNil(exporter.currentID)
        XCTAssertFalse(exporter.start(photos: [], context: context, catalog: catalog))
        XCTAssertEqual(exporter.completed, 2)
    }

    @MainActor
    func testRetryContinuesAfterLastConfirmedSuccessAndRefreshesPrivacyContext() async throws {
        let first = addPhoto(species: ["Elefant"], sightingIds: [])
        let second = addPhoto(species: ["Leopard"], sightingIds: [])
        let third = addPhoto(species: ["Impala"], sightingIds: [])
        var attempts: [UUID] = []
        var failOnce = true
        var receivedTimes: [[TimeInterval]] = []
        let exporter = PhotoExportController { photo, times, _ in
            attempts.append(photo.id); receivedTimes.append(times)
            if photo.id == second.id && failOnce { failOnce = false; throw Failure.interrupted }
        }
        exporter.start(photos: [first, second, third], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertEqual(exporter.completed, 1)
        XCTAssertEqual(exporter.remainingCount, 2)
        XCTAssertEqual(exporter.savedIDs, [first.id])
        XCTAssertNotNil(exporter.lastError)
        XCTAssertTrue(exporter.canRetry)
        XCTAssertFalse(exporter.canStart)
        XCTAssertFalse(exporter.start(photos: [third], context: context, catalog: catalog), "Ein Einzelbild darf die offene Restliste nicht ersetzen")
        XCTAssertEqual(exporter.remainingCount, 2)
        // Eine erst nach dem Fehler hinzugefügte geschützte Sichtung muss beim Wiederholen berücksichtigt werden.
        let rhino = addSighting("Breitmaulnashorn", position: coarsePosition)
        rhino.t = first.t
        try context.save()
        XCTAssertTrue(exporter.retry())
        XCTAssertFalse(exporter.retry())
        await exporter.waitUntilIdle()
        XCTAssertEqual(attempts, [first.id, second.id, second.id, third.id])
        XCTAssertEqual(exporter.completed, 3)
        XCTAssertEqual(exporter.remainingCount, 0)
        XCTAssertFalse(exporter.canRetry)
        XCTAssertNil(exporter.lastError)
        XCTAssertEqual(receivedTimes[2], [rhino.t.timeIntervalSince1970])
        XCTAssertEqual(receivedTimes[3], [rhino.t.timeIntervalSince1970])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoItem>()), 3, "Export erhält alle Originale")
    }

    @MainActor
    func testDeletedPendingPhotoFailsSafelyInsteadOfReportingSuccess() async throws {
        let first = addPhoto(species: ["Elefant"], sightingIds: [])
        let second = addPhoto(species: ["Leopard"], sightingIds: [])
        let secondID = second.id
        var failOnce = true
        var writes: [UUID] = []
        let exporter = PhotoExportController { photo, _, _ in
            if photo.id == secondID && failOnce { failOnce = false; throw Failure.interrupted }
            writes.append(photo.id)
        }
        exporter.start(photos: [first, second], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        context.delete(second); try context.save()
        XCTAssertTrue(exporter.retry())
        await exporter.waitUntilIdle()
        XCTAssertEqual(writes, [first.id])
        XCTAssertEqual(exporter.completed, 1)
        XCTAssertEqual(exporter.savedIDs, [first.id])
        XCTAssertTrue(exporter.lastError?.contains("nicht mehr in der App") == true)
        XCTAssertFalse(exporter.canRetry, "Wiederholen kann ein gelöschtes Foto nicht wiederherstellen")
        XCTAssertTrue(exporter.hasPendingJob)
        XCTAssertFalse(exporter.canStart)
    }

    @MainActor
    func testDiscardingFailedJobReleasesNextExportWithoutRemovingOriginals() async throws {
        let first = addPhoto(species: ["Elefant"], sightingIds: [])
        let second = addPhoto(species: ["Leopard"], sightingIds: [])
        var fail = true
        var writes: [UUID] = []
        let exporter = PhotoExportController { photo, _, _ in
            if fail { throw PhotoExporter.ExportError.metadata }
            writes.append(photo.id)
        }
        exporter.start(photos: [first], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertTrue(exporter.hasPendingJob)
        XCTAssertFalse(exporter.canRetry, "Ein defektes Bild kann nicht unverändert erneut kodiert werden")
        XCTAssertFalse(exporter.start(photos: [second], context: context, catalog: catalog))
        XCTAssertTrue(exporter.discardFailedJob())
        XCTAssertTrue(exporter.canStart)
        XCTAssertNil(exporter.lastError)
        XCTAssertEqual(exporter.remainingCount, 0)
        XCTAssertEqual(exporter.total, 0)
        XCTAssertTrue(exporter.savedIDs.isEmpty)
        fail = false
        XCTAssertTrue(exporter.start(photos: [second], context: context, catalog: catalog))
        await exporter.waitUntilIdle()
        XCTAssertEqual(writes, [second.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoItem>()), 2)
    }

    @MainActor
    func testSinglePhotoExportUsesSensitivePhotoOutsideSelection() async throws {
        let sensitive = addPhoto(species: ["Spitzmaulnashorn"], sightingIds: [])
        let other = addPhoto(species: ["Elefant"], sightingIds: [])
        other.t = sensitive.t.addingTimeInterval(600)
        try context.save()
        var protected = false
        let exporter = PhotoExportController { photo, times, catalog in
            XCTAssertEqual(photo.id, other.id)
            protected = PhotoExporter.requiresProtection(for: photo, isSensitive: catalog.isSensitive, protectedTimes: times)
        }
        exporter.start(photos: [other], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertTrue(protected)
        XCTAssertFalse(other.coarse, "Die Schutzregel für den Export verändert das Original nicht")
        XCTAssertEqual(exporter.savedIDs, [other.id])
        XCTAssertFalse(exporter.savedIDs.contains(sensitive.id), "Erfolg gehört ausschliesslich zum tatsächlich gesicherten Foto")
    }
}
