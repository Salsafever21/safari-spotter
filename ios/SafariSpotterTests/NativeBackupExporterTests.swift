import XCTest
import SwiftData
@testable import SafariSpotter

@MainActor
final class NativeBackupExporterTests: StoreTestCase {
    func testCorruptDrivePointsCannotProduceIncompleteBackup() throws {
        let drive = try Drive(startedAt: .now.addingTimeInterval(-60), endedAt: .now,
                              dist: 500, points: [], sightings: 0)
        drive.pointsJSON = Data("invalid".utf8)
        context.insert(drive)
        try context.save()
        XCTAssertThrowsError(try NativeBackupExporter.create(context: context))
    }

    func testCorruptPhotoDetectionsCannotProduceIncompleteBackup() throws {
        let photo = addPhoto(species: ["Elefant"], sightingIds: [])
        photo.detsJSON = Data("invalid".utf8)
        try context.save()
        XCTAssertThrowsError(try NativeBackupExporter.create(context: context))
    }

    func testCameraSettingsSurviveNativeBackup() throws {
        let settings = AppSettings.shared
        let originalLens = settings.lensID, originalBurnIn = settings.burnIn
        defer { settings.lensID = originalLens; settings.burnIn = originalBurnIn }
        settings.lensID = "lens-from-backup"
        settings.burnIn = false
        let raw = try NativeBackupExporter.create(context: context)
        defer { try? FileManager.default.removeItem(at: raw) }
        settings.lensID = ""
        settings.burnIn = true
        let restored = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let result = try WebBackupImporter.perform(url: raw, context: ModelContext(restored))
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        XCTAssertEqual(settings.lensID, "lens-from-backup")
        XCTAssertFalse(settings.burnIn)
    }

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
        let drive = try Drive(startedAt: .now.addingTimeInterval(-60), endedAt: .now,
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

    func testEncryptedImportRetainsOnlyEncryptedArchive() throws {
        addSighting("Elefant")
        let raw = try NativeBackupExporter.create(context: context)
        defer { try? FileManager.default.removeItem(at: raw) }
        let encrypted = try EncryptedBackup.encrypt(raw, password: "test backup password long enough")
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let decrypted = try EncryptedBackup.decrypt(encrypted, password: "test backup password long enough")
        defer { try? FileManager.default.removeItem(at: decrypted) }

        let restored = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let result = try WebBackupImporter.perform(url: decrypted, context: ModelContext(restored), archivedSource: encrypted)
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        XCTAssertEqual(result.sightings, 1)
        XCTAssertEqual(try Data(contentsOf: result.archiveURL).prefix(6), Data("SSBE1\n".utf8))
        XCTAssertEqual(try Data(contentsOf: result.archiveURL), try Data(contentsOf: encrypted))

        // Two protected files may contain identical core data but different videos.
        // Keep both originals instead of using the core checksum as the archive name.
        let second = try EncryptedBackup.encrypt(raw, password: "another backup password")
        defer { try? FileManager.default.removeItem(at: second) }
        let secondDecrypted = try EncryptedBackup.decrypt(second, password: "another backup password")
        defer { try? FileManager.default.removeItem(at: secondDecrypted) }
        let secondResult = try WebBackupImporter.perform(url: secondDecrypted, context: ModelContext(restored), archivedSource: second)
        defer { try? FileManager.default.removeItem(at: secondResult.archiveURL) }
        XCTAssertNotEqual(secondResult.archiveURL, result.archiveURL)
        XCTAssertEqual(try Data(contentsOf: secondResult.archiveURL), try Data(contentsOf: second))
    }

    func testEncryptedNativeArchiveRestoresPhotoSightingAndClipTogether() throws {
        let sighting = addSighting("Elefant")
        let photo = addPhoto(species: ["Elefant"], sightingIds: [sighting.id])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clips = root.appendingPathComponent("Clips")
        let restoredClips = root.appendingPathComponent("RestoredClips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let clipID = UUID()
        let clipBytes = Data(repeating: 49, count: 2_100_000)
        try clipBytes.write(to: ClipFiles.movieURL(clipID, in: clips))
        var clip = ClipRecord(id: clipID, createdAt: .now, burnedIn: false, trackingActive: false, state: .complete)
        clip.fileSize = Int64(clipBytes.count)
        clip.duration = 3
        try ClipFiles.save(clip, in: clips)

        let raw = try NativeBackupExporter.create(context: context)
        defer { try? FileManager.default.removeItem(at: raw) }
        let bundle = try NativeArchive.create(core: raw, clipsDirectory: clips)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let encrypted = try EncryptedBackup.encrypt(bundle, password: "complete backup password")
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let decrypted = try EncryptedBackup.decrypt(encrypted, password: "complete backup password")
        defer { try? FileManager.default.removeItem(at: decrypted) }
        let contents = try NativeArchive.extract(decrypted)
        defer { contents.removeTemporaryFiles() }
        let restored = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let newContext = ModelContext(restored)
        let result = try WebBackupImporter.perform(url: contents.core, context: newContext, archivedSource: encrypted)
        defer { try? FileManager.default.removeItem(at: result.archiveURL) }
        try NativeArchive.installClips(contents, clipsDirectory: restoredClips)

        XCTAssertEqual(result.sightings, 1)
        XCTAssertEqual(result.photos, 1)
        XCTAssertEqual(try newContext.fetch(FetchDescriptor<PhotoItem>()).first?.image, photo.image)
        XCTAssertEqual(try Data(contentsOf: ClipFiles.movieURL(clipID, in: restoredClips)), clipBytes)
        XCTAssertEqual(ClipFiles.list(in: restoredClips).first?.id, clipID)
        XCTAssertEqual(try Data(contentsOf: result.archiveURL).prefix(6), Data("SSBE1\n".utf8))
    }
}
