import XCTest
import SwiftData
@testable import SafariSpotter

@MainActor
final class NativeBackupExporterTests: StoreTestCase {
    func testNativeBackupRestoresDataAndCanBeImportedTwice() throws {
        let sighting = addSighting("Breitmaulnashorn", position: coarsePosition)
        let photo = addPhoto(species: ["Breitmaulnashorn"], position: coarsePosition,
                             sightingIds: [sighting.id])
        let cameraPhoto = PhotoItem(t: .now, kind: "cam", species: [], dets: [], image: Self.jpeg(),
                                    thumb: nil, width: 8, height: 8, position: nil, sightingIds: [])
        context.insert(cameraPhoto)
        let correction = Correction(image: Self.jpeg(), predicted: "Löwe", predKey: nil,
                                    conf: 0.7, label: "Breitmaulnashorn", labelKey: nil,
                                    status: "corrected", region: nil)
        context.insert(correction)
        let drive = Drive(startedAt: .now.addingTimeInterval(-60), endedAt: .now,
                          dist: 500, points: [], sightings: 1)
        context.insert(drive)
        try context.save()

        let url = try NativeBackupExporter.create(context: context)
        defer { try? FileManager.default.removeItem(at: url) }
        let restored = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let newContext = ModelContext(restored)
        let result = try WebBackupImporter.perform(url: url, context: newContext)
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        XCTAssertEqual(result.sightings, 1)
        XCTAssertEqual(result.photos, 2)
        XCTAssertEqual(result.corrections, 1)
        XCTAssertEqual(result.drives, 1)
        XCTAssertEqual(try newContext.fetch(FetchDescriptor<Sighting>()).first?.id, sighting.id)
        let restoredPhotos = try newContext.fetch(FetchDescriptor<PhotoItem>())
        XCTAssertEqual(restoredPhotos.first(where: { $0.id == photo.id })?.image, photo.image)
        XCTAssertTrue(try XCTUnwrap(restoredPhotos.first(where: { $0.id == photo.id })).coarse)
        XCTAssertEqual(restoredPhotos.first(where: { $0.id == cameraPhoto.id })?.kind, "cam")
        XCTAssertEqual(restoredPhotos.first(where: { $0.id == cameraPhoto.id })?.image, cameraPhoto.image)
        XCTAssertEqual(try newContext.fetch(FetchDescriptor<Drive>()).first?.id, drive.id)
        let again = try WebBackupImporter.perform(url: url, context: newContext)
        XCTAssertEqual(again.sightings + again.photos + again.corrections + again.drives, 0)
    }
}
