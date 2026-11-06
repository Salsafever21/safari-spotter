import XCTest
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
@testable import SafariSpotter

/// Nashorn-Standorte: Umbenennen schützt Sichtung und verknüpfte Fotos, der Export schreibt nie eine genaue Nashorn-Position
/// und übernimmt nie GPS aus der Quelle (Befunde D2, D3)
final class LocationProtectionTests: StoreTestCase {
    func testCatalogMarksRhinos() throws {
        XCTAssertTrue(isSensitive("Breitmaulnashorn"))
        XCTAssertTrue(isSensitive("Spitzmaulnashorn"))
        XCTAssertTrue(isSensitive("Nashorn"))      // Sammelname bei knapper Entscheidung
        XCTAssertFalse(isSensitive("Elefant"))
    }

    func testRenameToRhinoCoarsensSightingAndLinkedPhotos() throws {
        let s = addSighting("Elefant")
        let linked = addPhoto(species: ["Elefant"], sightingIds: [s.id])
        let other = addPhoto(species: ["Impala"], sightingIds: [UUID()])
        try store.rename(s, to: "Breitmaulnashorn", key: "breitmaulnashorn")
        let c = coarsePosition
        XCTAssertTrue(s.coarse); XCTAssertEqual(s.lat, c.lat); XCTAssertEqual(s.lon, c.lon); XCTAssertEqual(s.acc, 10000)
        XCTAssertTrue(linked.coarse, "verknüpftes Foto muss ungenau werden")
        XCTAssertEqual(linked.lat, c.lat); XCTAssertEqual(linked.lon, c.lon)
        XCTAssertEqual(linked.species, ["Breitmaulnashorn"])
        XCTAssertFalse(other.coarse, "fremdes Foto bleibt unverändert"); XCTAssertEqual(other.lat, exact.lat)
    }

    func testRenameToHarmlessSpeciesStaysExact() throws {
        let s = addSighting("Elefant")
        let p = addPhoto(species: ["Elefant"], sightingIds: [s.id])
        try store.rename(s, to: "Impala", key: "impala")
        XCTAssertFalse(s.coarse); XCTAssertEqual(s.lat, exact.lat)
        XCTAssertFalse(p.coarse); XCTAssertEqual(p.lat, exact.lat); XCTAssertEqual(p.species, ["Impala"])
    }

    /// `coarsen` ist beim Längengrad nicht idempotent: schon vergröberte Daten dürfen sich nicht verschieben
    func testAlreadyCoarseDataIsNotCoarsenedTwice() throws {
        let c = coarsePosition
        let s = addSighting("Spitzmaulnashorn", position: c)
        let p = addPhoto(species: ["Spitzmaulnashorn"], position: c, sightingIds: [s.id])
        try store.rename(s, to: "Breitmaulnashorn", key: "breitmaulnashorn")
        XCTAssertEqual(s.lat, c.lat); XCTAssertEqual(s.lon, c.lon)
        XCTAssertEqual(p.lat, c.lat); XCTAssertEqual(p.lon, c.lon)
    }

    func testExportCoordinate() throws {
        let c = coarsePosition
        let rhinoBox = PhotoDet(x: 0, y: 0, w: 4, h: 4, name: "Spitzmaulnashorn", conf: 0.8, sure: true)
        let withRhinoBox = addPhoto(species: ["Impala"], dets: [rhinoBox], sightingIds: [])
        let e = PhotoExporter.exportCoordinate(for: withRhinoBox, isSensitive: isSensitive)
        XCTAssertEqual(e?.latitude, c.lat, "Nashorn nur als Rahmen im Bild: Export auf dem Raster"); XCTAssertEqual(e?.longitude, c.lon)
        let harmless = addPhoto(species: ["Impala"], sightingIds: [])
        XCTAssertEqual(PhotoExporter.exportCoordinate(for: harmless, isSensitive: isSensitive)?.latitude, exact.lat)
        let alreadyCoarse = addPhoto(species: ["Nashorn"], position: c, sightingIds: [])
        XCTAssertEqual(PhotoExporter.exportCoordinate(for: alreadyCoarse, isSensitive: isSensitive)?.longitude, c.lon)
        let noGPS = addPhoto(species: ["Breitmaulnashorn"], located: false, sightingIds: [])
        XCTAssertNil(PhotoExporter.exportCoordinate(for: noGPS, isSensitive: isSensitive))
    }

    func testJpegWithoutCoordinateRemovesSourceGPS() throws {
        let src = Self.jpeg(gps: CLLocationCoordinate2D(latitude: exact.lat, longitude: exact.lon))
        XCTAssertNotNil(PhotoExporter.gpsCoordinate(of: src), "Voraussetzung: Quelle hat GPS")
        let out = PhotoExporter.jpegWithMetadata(src, date: .now, coordinate: nil, description: "Test")
        XCTAssertFalse(out.isEmpty)
        XCTAssertNil(PhotoExporter.gpsCoordinate(of: out), "GPS der Quelle darf nicht mitgehen")
    }

    func testJpegWritesProtectedCoordinateOverSourceGPS() throws {
        let src = Self.jpeg(gps: CLLocationCoordinate2D(latitude: exact.lat, longitude: exact.lon))
        let c = coarsePosition
        let out = PhotoExporter.jpegWithMetadata(src, date: .now, coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), description: "Test")
        let got = try XCTUnwrap(PhotoExporter.gpsCoordinate(of: out))
        XCTAssertEqual(got.latitude, c.lat, accuracy: 1e-4)
        XCTAssertEqual(got.longitude, c.lon, accuracy: 1e-4)
    }

    func testProtectedPhotoExportRemovesOriginalTimeMetadata() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Self.jpeg() as CFData, nil))
        let raw = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(raw as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:06 10:23:45", kCGImagePropertyExifSubsecTimeOriginal: "123"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCDateCreated: "20261106", kCGImagePropertyIPTCTimeCreated: "102345+0000"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let rounded = Exporters.hourFloor(date)
        let output = PhotoExporter.jpegWithMetadata(raw as Data, date: rounded, coordinate: nil,
                                                     description: "Nashorn", stripSourceMetadata: true)
        let result = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, formatter.string(from: rounded))
        XCTAssertNil(exif[kCGImagePropertyExifSubsecTimeOriginal])
        // ImageIO kann aus den neuen, gerundeten EXIF-Daten wieder IPTC-Felder erzeugen.
        // Entscheidend ist, dass sie keine ursprüngliche genaue Zeit mehr enthalten.
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            formatter.dateFormat = "yyyyMMdd"
            if let date = iptc[kCGImagePropertyIPTCDateCreated] as? String {
                XCTAssertEqual(date, formatter.string(from: rounded))
            }
            formatter.dateFormat = "HHmmss"
            for key in [kCGImagePropertyIPTCTimeCreated, kCGImagePropertyIPTCDigitalCreationTime] {
                if let time = iptc[key] as? String { XCTAssertEqual(String(time.prefix(6)), formatter.string(from: rounded)) }
            }
        }
    }
}
