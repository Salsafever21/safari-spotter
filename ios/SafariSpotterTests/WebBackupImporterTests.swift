import XCTest
import SwiftData
import CryptoKit
@testable import SafariSpotter

@MainActor
final class WebBackupImporterTests: StoreTestCase {
    func testImportPreservesPhotosAndDoesNotDuplicateRecords() throws {
        let photo = StoreTestCase.jpeg()
        let (url, file) = try makeArchive(photo: photo)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try WebBackupImporter.perform(url: url, context: context)
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        XCTAssertEqual(result.sightings, 1)
        XCTAssertEqual(result.photos, 1)
        XCTAssertEqual(result.corrections, 1)
        XCTAssertEqual(result.drives, 1)
        XCTAssertEqual(try Data(contentsOf: result.archiveURL), file)

        let sighting = try XCTUnwrap(context.fetch(FetchDescriptor<Sighting>()).first)
        let image = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoItem>()).first)
        XCTAssertEqual(image.image, photo)
        XCTAssertEqual(image.sightingIds, [sighting.id])
        XCTAssertTrue(sighting.coarse)
        XCTAssertTrue(image.coarse) // Linked rhino sighting protects even an unlabelled photo.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Correction>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Drive>()).count, 1)

        let again = try WebBackupImporter.perform(url: url, context: context)
        XCTAssertEqual(again.sightings + again.photos + again.corrections + again.drives, 0)
    }

    func testCorruptPhotoIsRejectedBeforeWriting() throws {
        let (url, _) = try makeArchive(photo: StoreTestCase.jpeg(), corruptHash: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try WebBackupImporter.perform(url: url, context: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Sighting>()).count, 0)
    }

    func testNashornvogelDoesNotLosePrecisePosition() throws {
        let (url, _) = try makeArchive(photo: StoreTestCase.jpeg(), sightingName: "Nashornvogel")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try WebBackupImporter.perform(url: url, context: context)
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        let sighting = try XCTUnwrap(context.fetch(FetchDescriptor<Sighting>()).first)
        let photo = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoItem>()).first)
        XCTAssertFalse(sighting.coarse)
        XCTAssertFalse(photo.coarse)
        XCTAssertEqual(sighting.lat, -24.98765)
        XCTAssertEqual(photo.lon, 31.54321)
    }

    private func makeArchive(photo: Data, corruptHash: Bool = false, sightingName: String = "Breitmaulnashorn") throws -> (URL, Data) {
        let checksum = SHA256.hash(data: photo).map { String(format: "%02x", $0) }.joined()
        let thumb = "data:image/jpeg;base64," + photo.base64EncodedString()
        let manifest: [String: Any] = [
            "format": "safari-spotter-backup", "version": 1, "createdAt": "2026-11-05T08:00:00.000Z",
            "origin": "https://example.test", "sourceVersion": "1.5.1", "binaryLength": photo.count,
            "counts": ["sightings": 1, "photos": 1, "corrections": 1, "completedDrives": 1, "activeDrive": false],
            "stored": ["ss.settings": "{}"],
            "snapshot": [
                "settings": ["threshold": 0.4],
                "sightings": [["id": "s1", "s": sightingName, "t": 1_762_336_000_000 as Double,
                               "n": 1, "lat": -24.98765, "lon": 31.54321, "acc": 5]],
                "trip": ["active": false, "startedAt": 0, "points": [], "dist": 0],
                "trips": [["startedAt": 1_762_336_000_000 as Double, "endedAt": 1_762_336_060_000 as Double,
                           "dist": 123.0, "points": [[1_762_336_000_000 as Double, -24.98, 31.54, 2.0, 300.0]], "sightings": 1]]
            ],
            "photos": [["metadata": ["id": 7, "t": 1_762_336_000_000 as Double, "kind": "auto", "species": [],
                                      "dets": [], "w": 8, "h": 8, "sightIds": ["s1"], "lat": -24.98765,
                                      "lon": 31.54321, "acc": 5, "thumb": thumb],
                        "offset": 0, "length": photo.count, "type": "image/jpeg",
                        "sha256": corruptHash ? String(repeating: "0", count: 64) : checksum]],
            "corrections": [["id": 3, "t": 1_762_336_000_000 as Double, "img": thumb,
                             "predicted": "Löwe", "status": "corrected", "label": "Breitmaulnashorn"]]
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest)
        var file = Data("SSBK1\n".utf8)
        file.append(contentsOf: (0..<8).map { UInt8((UInt64(json.count) >> ($0 * 8)) & 0xff) })
        file.append(json)
        file.append(photo)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ssbackup")
        try file.write(to: url)
        return (url, file)
    }
}
