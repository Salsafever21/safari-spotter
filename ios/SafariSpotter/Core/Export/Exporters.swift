import Foundation
import CoreLocation
import Photos
import ImageIO
import UniformTypeIdentifiers

/// Exporte mit Artenschutz: Nashorn-Sichtungen nur mit 10-km-Raster und auf die Stunde gerundeter Zeit, Spur ±15 min ausgeblendet.
enum Exporters {
    static func hourFloor(_ d: Date) -> Date { Date(timeIntervalSince1970: floor(d.timeIntervalSince1970 / 3600) * 3600) }

    static func csv(sightings: [Sighting], catalog: SpeciesCatalog) -> String {
        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"; let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        var rows = ["Datum;Zeit;Art;Anzahl;Breite;Laenge;Genauigkeit"]
        for s in sightings {
            let sens = s.coarse || catalog.isSensitive(name: s.name)
            let t = sens ? hourFloor(s.t) : s.t
            let prec = s.lat == nil ? "" : sens ? "±10 km (Artenschutz)" : "±\(Int(s.acc ?? 0)) m"
            let lat = s.lat.map { String(format: sens ? "%.2f" : "%.5f", $0) } ?? "", lon = s.lon.map { String(format: sens ? "%.2f" : "%.5f", $0) } ?? ""
            rows.append([df.string(from: t), tf.string(from: t) + (sens ? " (gerundet)" : ""), s.name, String(s.n), lat, lon, prec].joined(separator: ";"))
        }
        return "\u{FEFF}" + rows.joined(separator: "\n")
    }

    static func gpx(points: [TrackPoint], sightings: [Sighting], catalog: SpeciesCatalog, version: String) -> String {
        let iso = ISO8601DateFormatter()
        let sensTimes = sightings.filter { $0.coarse || catalog.isSensitive(name: $0.name) }.map { $0.t.timeIntervalSince1970 }
        func hidden(_ t: TimeInterval) -> Bool { sensTimes.contains { abs(t - $0) < 15 * 60 } }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var g = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Safari Spotter iOS \(version)\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        for s in sightings { guard let lat = s.lat, let lon = s.lon else { continue }
            let sens = s.coarse || catalog.isSensitive(name: s.name)
            let t = sens ? hourFloor(s.t) : s.t
            g += "  <wpt lat=\"\(String(format: sens ? "%.3f" : "%.5f", lat))\" lon=\"\(String(format: sens ? "%.3f" : "%.5f", lon))\"><time>\(iso.string(from: t))</time><name>\(esc(s.name))\(s.n > 1 ? " (\(s.n))" : "")</name><desc>\(sens ? "±10 km (Artenschutz)" : "±\(Int(s.acc ?? 0)) m")</desc></wpt>\n"
        }
        if !points.isEmpty {
            g += "  <trk><name>Safari</name><trkseg>\n"; var open = true
            for p in points {
                if hidden(p.t) { if open { g += "  </trkseg><trkseg>\n"; open = false }; continue }
                open = true
                g += "    <trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">\(p.alt.map { "<ele>\($0)</ele>" } ?? "")<time>\(iso.string(from: Date(timeIntervalSince1970: p.t)))</time></trkpt>\n"
            }
            g += "  </trkseg></trk>\n"
        }
        return g + "</gpx>\n"
    }

    /// Schreibt Text in eine temporäre Datei zum Teilen (ShareLink)
    static func tempFile(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return (try? text.data(using: .utf8)?.write(to: url)) != nil ? url : nil
    }
}

/// Fotos-App: Bild mit Aufnahmedatum, Standort und Beschreibung (EXIF/TIFF) sichern, so erscheint es auf der Orte-Karte.
enum PhotoExporter {
    static func jpegWithMetadata(_ jpeg: Data, date: Date, coordinate: CLLocationCoordinate2D?, description: String) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let type = CGImageSourceGetType(src) else { return jpeg }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return jpeg }
        let df = DateFormatter(); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description, kCGImagePropertyTIFFSoftware: "Safari Spotter", kCGImagePropertyTIFFDateTime: df.string(from: date)],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: df.string(from: date), kCGImagePropertyExifDateTimeDigitized: df.string(from: date)]
        ]
        if let c = coordinate {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(c.latitude), kCGImagePropertyGPSLatitudeRef: c.latitude < 0 ? "S" : "N",
                                                    kCGImagePropertyGPSLongitude: abs(c.longitude), kCGImagePropertyGPSLongitudeRef: c.longitude < 0 ? "W" : "E"]
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : jpeg
    }

    static func save(_ photo: PhotoItem, jpeg: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: jpeg, options: nil)
            req.creationDate = photo.t
            if let c = photo.coordinate { req.location = CLLocation(latitude: c.latitude, longitude: c.longitude) }
        }
    }
}
