import XCTest
import CoreLocation
import ImageIO
@testable import SafariSpotter

final class PhotoExportPreparationTests: StoreTestCase {
    @MainActor
    func testUnreadableProtectionDataStopsDirectExportBeforePhotoLibraryAccess() async {
        let photo = addPhoto(species: ["Elefant"], sightingIds: [])
        photo.detsJSON = Data([0, 1, 2])
        do {
            try await PhotoExporter.export(photo, isSensitive: isSensitive, protectedTimes: [])
            XCTFail("Unlesbare Artenschutzdaten dürfen keinen Export erlauben")
        } catch PhotoExporter.ExportError.protectionData {
            XCTAssertEqual(photo.detsJSON, Data([0, 1, 2]))
        } catch { XCTFail("Falscher Fehler: \(error)") }
    }

    @MainActor
    func testProtectedSnapshotRunsOffMainThreadAndDoesNotReadLaterModelChanges() async throws {
        let photo = addPhoto(species: ["Spitzmaulnashorn"], sightingIds: [])
        photo.image = Self.jpeg(gps: CLLocationCoordinate2D(latitude: exact.lat, longitude: exact.lon))
        photo.t = Date(timeIntervalSince1970: 1_700_000_123)
        let original = photo.image
        let rounded = Exporters.hourFloor(photo.t)
        let input = PhotoExporter.snapshot(photo, isSensitive: isSensitive, protectedTimes: [])
        // Nach der Übergabe darf der Hintergrund nur den unveränderlichen, bereits geschützten Stand verwenden.
        photo.species = ["Elefant"]; photo.t = .now; photo.image = Data([0, 1, 2])
        let result = try await PhotoExporter.prepareInBackground(input) { snapshot in
            XCTAssertFalse(Thread.isMainThread, "Bildaufbereitung darf den Main Actor nicht blockieren")
            return try PhotoExporter.prepare(snapshot)
        }
        XCTAssertEqual(result.date, rounded)
        XCTAssertEqual(result.latitude, coarsePosition.lat)
        XCTAssertEqual(result.longitude, coarsePosition.lon)
        let gps = try XCTUnwrap(PhotoExporter.gpsCoordinate(of: result.jpeg))
        XCTAssertEqual(gps.latitude, coarsePosition.lat, accuracy: 0.0001)
        XCTAssertEqual(gps.longitude, coarsePosition.lon, accuracy: 0.0001)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, formatter.string(from: rounded))
        // ImageIO kann die TIFF-Beschreibung beim JPEG-Schreiben als IPTC-Bildunterschrift normalisieren.
        let description = tiff?[kCGImagePropertyTIFFImageDescription] as? String
            ?? iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String
        XCTAssertEqual(description, "Safari Spotter: Spitzmaulnashorn")
        XCTAssertEqual(input.image, original)
        XCTAssertEqual(photo.image, Data([0, 1, 2]), "Der Export darf neuere Originaldaten nicht zurückschreiben")
    }

    @MainActor
    func testOrdinaryPhotoKeepsRequestedMetadataWithoutLeakingSourceGPS() async throws {
        let photo = addPhoto(species: ["Leopard"], located: false, sightingIds: [])
        photo.image = Self.jpeg(gps: CLLocationCoordinate2D(latitude: exact.lat, longitude: exact.lon))
        let input = PhotoExporter.snapshot(photo, isSensitive: isSensitive, protectedTimes: [])
        let result = try await PhotoExporter.prepareInBackground(input)
        XCTAssertEqual(result.date, photo.t)
        XCTAssertNil(result.latitude)
        XCTAssertNil(result.longitude)
        XCTAssertNil(PhotoExporter.gpsCoordinate(of: result.jpeg), "Quell-GPS darf nicht ohne App-Standort mitkommen")
        XCTAssertNotNil(CGImageSourceCreateWithData(result.jpeg as CFData, nil))
        XCTAssertEqual(photo.image, input.image)
    }

    @MainActor
    func testUnreadablePhotoFailsBeforePhotoLibraryAccessAndKeepsOriginal() async {
        let photo = addPhoto(species: ["Elefant"], located: false, sightingIds: [])
        photo.image = Data([0, 1, 2])
        do {
            try await PhotoExporter.export(photo, isSensitive: isSensitive, protectedTimes: [])
            XCTFail("Unlesbare Bytes dürfen nicht als Erfolg gelten")
        } catch PhotoExporter.ExportError.invalidImage {
            XCTAssertEqual(photo.image, Data([0, 1, 2]))
        } catch {
            XCTFail("Bildprüfung muss vor jeder Mediathek-Berechtigung fehlschlagen: \(error)")
        }
    }

    @MainActor
    func testCanceledPreparationDoesNotInvokeProcessor() async {
        let photo = addPhoto(species: ["Elefant"], sightingIds: [])
        let input = PhotoExporter.snapshot(photo, isSensitive: isSensitive, protectedTimes: [])
        let task = Task {
            do {
                _ = try await PhotoExporter.prepareInBackground(input) { _ in
                    XCTFail("Ein vorab abgebrochener Export darf keine Verarbeitung starten")
                    throw PhotoExporter.ExportError.metadata
                }
                XCTFail("Abbruch muss weitergegeben werden")
            } catch is CancellationError {} catch { XCTFail("Falscher Fehler: \(error)") }
        }
        task.cancel()
        await task.value
    }
}
