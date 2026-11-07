import XCTest
@testable import SafariSpotter

final class ClipLibraryTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("Clips", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clip-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func addClip() throws -> ClipRecord {
        var record = ClipRecord(id: UUID(), createdAt: .now, burnedIn: false, trackingActive: false, state: .complete)
        let bytes = Data("gespeichertes Originalvideo".utf8)
        record.fileSize = Int64(bytes.count)
        try bytes.write(to: ClipFiles.movieURL(record.id, in: directory))
        try ClipFiles.save(record, in: directory)
        return record
    }

    private func blockDirectory() throws -> URL {
        let preserved = root.appendingPathComponent("Originale", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: preserved)
        try Data("vorübergehend nicht als Ordner lesbar".utf8).write(to: directory)
        return preserved
    }

    func testDirectoryReadFailuresCannotLookLikeAnEmptyClipIndex() throws {
        let original = try addClip()
        let preserved = try blockDirectory()
        XCTAssertThrowsError(try ClipFiles.list(in: directory))
        XCTAssertThrowsError(try ClipFiles.orphanMovies(in: directory))
        XCTAssertEqual(try Data(contentsOf: ClipFiles.movieURL(original.id, in: preserved)),
                       Data("gespeichertes Originalvideo".utf8))
    }

    @MainActor
    func testReloadKeepsLastKnownClipsOnReadFailureAndRefreshesAfterRetry() throws {
        let original = try addClip()
        let library = ClipLibrary(directory: directory)
        XCTAssertEqual(library.clips.map(\.id), [original.id])
        XCTAssertNil(library.loadError)
        let preserved = try blockDirectory()
        library.reload()
        XCTAssertEqual(library.clips.map(\.id), [original.id], "Ein Lesefehler darf keine leere Galerie vortäuschen")
        XCTAssertTrue(library.loadError?.contains("nichts gelöscht") == true)
        try FileManager.default.removeItem(at: directory) // nur die künstliche blockierende Datei
        try FileManager.default.moveItem(at: preserved, to: directory)
        let added = try addClip()
        library.reload()
        XCTAssertNil(library.loadError)
        XCTAssertEqual(Set(library.clips.map(\.id)), [original.id, added.id])
        XCTAssertEqual(try Data(contentsOf: ClipFiles.movieURL(original.id, in: directory)),
                       Data("gespeichertes Originalvideo".utf8))
    }

    @MainActor
    func testFailedRecoveryEnumerationReportsErrorAndRemainsRetryable() async throws {
        let orphan = UUID()
        let bytes = Data("unvollständige Aufnahme".utf8)
        try bytes.write(to: ClipFiles.movieURL(orphan, in: directory))
        let preserved = try blockDirectory()
        let report = await ClipFiles.recoverInterrupted(in: directory) { _ in
            XCTFail("Ohne lesbaren Index dürfen keine Videos geprüft werden")
            return nil
        }
        XCTAssertNotNil(report.directoryError)
        XCTAssertTrue(report.changed.isEmpty)
        let library = ClipLibrary(directory: directory)
        await library.recoverInterrupted(excluding: nil)
        XCTAssertNotNil(library.loadError)
        XCTAssertNotNil(library.recoveryError)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: preserved, to: directory)
        await library.recoverInterrupted(excluding: nil)
        XCTAssertNil(library.loadError)
        XCTAssertNil(library.recoveryError)
        XCTAssertEqual(library.clips.map(\.id), [orphan], "Ein fehlgeschlagener Versuch darf Wiederherstellung nicht als erledigt markieren")
        XCTAssertEqual(library.clips.first?.state, .damaged)
        XCTAssertEqual(try Data(contentsOf: ClipFiles.movieURL(orphan, in: directory)), bytes)
    }

    @MainActor
    func testDeletingFromUnreadableDirectoryDoesNotClaimSuccessOrRemoveOriginal() throws {
        let original = try addClip()
        let library = ClipLibrary(directory: directory)
        let preserved = try blockDirectory()
        XCTAssertThrowsError(try library.delete(original))
        XCTAssertEqual(library.clips.map(\.id), [original.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipFiles.movieURL(original.id, in: preserved).path))
        XCTAssertNotNil(ClipFiles.load(original.id, in: preserved))
    }
}
