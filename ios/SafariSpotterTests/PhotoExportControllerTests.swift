import XCTest
import SwiftData
@testable import SafariSpotter

final class PhotoExportControllerTests: StoreTestCase {
    private enum Failure: Error { case interrupted }

    @MainActor
    func testUnreadableProtectionDataStopsAllWritesAndCannotBeSkipped() async throws {
        let selected = addPhoto(species: ["Elefant"], sightingIds: [])
        let other = addPhoto(species: ["Leopard"], sightingIds: [])
        other.detsJSON = Data([0, 1, 2])
        try context.save()
        var writes = 0
        let exporter = PhotoExportController { _, _, _ in writes += 1 }
        exporter.start(photos: [selected], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertEqual(writes, 0, "Ein unlesbarer Schutzkontext muss vor jedem Schreiben abbrechen")
        XCTAssertTrue(exporter.hasPendingJob)
        XCTAssertTrue(exporter.canRetry)
        XCTAssertFalse(exporter.canSkip)
        XCTAssertFalse(exporter.skipFailedPhoto(), "Überspringen darf den Schutzkontext nicht umgehen")
        XCTAssertEqual(exporter.completed, 0)
        XCTAssertEqual(exporter.remainingCount, 1)
        XCTAssertTrue(exporter.lastError?.contains("Artenschutz-Informationen") == true)
        XCTAssertEqual(other.detsJSON, Data([0, 1, 2]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoItem>()), 2)
    }

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
        XCTAssertFalse(exporter.skipFailedPhoto(), "Laufende Exporte sind nicht überspringbar")
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
        XCTAssertFalse(exporter.canSkip, "Ein allgemeiner Schreibfehler darf nicht versehentlich übersprungen werden")
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
        XCTAssertTrue(exporter.canSkip)
    }

    @MainActor
    func testSkippingBrokenPhotoContinuesBatchAndKeepsItsPrivacyContextAndOriginal() async throws {
        let first = addPhoto(species: ["Elefant"], sightingIds: [])
        let broken = addPhoto(species: ["Breitmaulnashorn"], sightingIds: [])
        let last = addPhoto(species: ["Leopard"], sightingIds: [])
        broken.image = Data([0, 1, 2])
        last.t = broken.t.addingTimeInterval(180)
        try context.save()
        var attempts: [UUID] = []
        let exporter = PhotoExportController { photo, times, catalog in
            attempts.append(photo.id)
            if photo.id == broken.id { throw PhotoExporter.ExportError.invalidImage }
            if photo.id == last.id {
                XCTAssertTrue(PhotoExporter.requiresProtection(for: photo, isSensitive: catalog.isSensitive, protectedTimes: times),
                              "Auch das übersprungene Nashorn muss seine Nachbarfotos weiterhin schützen")
            }
        }
        exporter.start(photos: [first, broken, last], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertTrue(exporter.canSkip)
        XCTAssertEqual(exporter.completed, 1)
        XCTAssertTrue(exporter.skipFailedPhoto())
        XCTAssertFalse(exporter.skipFailedPhoto(), "Die fortgesetzte Serie darf nicht nochmals übersprungen werden")
        await exporter.waitUntilIdle()
        XCTAssertEqual(attempts, [first.id, broken.id, last.id])
        XCTAssertEqual(exporter.savedIDs, [first.id, last.id])
        XCTAssertEqual(exporter.skippedIDs, [broken.id])
        XCTAssertEqual(exporter.completed, 2)
        XCTAssertEqual(exporter.total, 3)
        XCTAssertTrue(exporter.canStart)
        XCTAssertNil(exporter.lastError)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoItem>()), 3)
        XCTAssertEqual(broken.image, Data([0, 1, 2]))
    }

    @MainActor
    func testSkippingOnlyRemainingPhotoFinishesWithoutClaimingItWasSaved() async {
        let photo = addPhoto(species: ["Leopard"], sightingIds: [])
        let exporter = PhotoExportController { _, _, _ in throw PhotoExporter.ExportError.metadata }
        exporter.start(photos: [photo], context: context, catalog: catalog)
        await exporter.waitUntilIdle()
        XCTAssertTrue(exporter.skipFailedPhoto())
        XCTAssertEqual(exporter.completed, 0)
        XCTAssertEqual(exporter.skippedIDs, [photo.id])
        XCTAssertTrue(exporter.savedIDs.isEmpty)
        XCTAssertEqual(exporter.remainingCount, 0)
        XCTAssertFalse(exporter.hasPendingJob)
        XCTAssertFalse(exporter.canSkip)
        XCTAssertTrue(exporter.canStart)
        exporter.start(photos: [photo], context: context, catalog: catalog)
        XCTAssertTrue(exporter.skippedIDs.isEmpty, "Ein neuer Auftrag beginnt ohne alte Überspringen-Zählung")
        await exporter.waitUntilIdle()
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
