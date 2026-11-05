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
/// Artenschutz: Die Position, mit der ein Foto die App verlässt, kommt immer aus `exportCoordinate` (zweite Absicherung,
/// greift auch bei Fotos, die vor dieser Regel oder per Import gespeichert wurden).
enum PhotoExporter {
    enum ExportError: LocalizedError {
        case denied, metadata
        var errorDescription: String? {
            switch self {
            case .denied: return "Kein Zugriff auf die Fotos-Mediathek. Bitte in den Einstellungen unter Safari Spotter › Fotos „Nur hinzufügen“ erlauben."
            case .metadata: return "Die Bildinformationen konnten nicht sicher geschrieben werden; das Foto wurde nicht gesichert."
            }
        }
    }

    /// Exportposition: schon vergröbert bleibt, sensible Art in Artenliste **oder** Rahmen → 10-km-Raster, sonst genau
    static func exportCoordinate(for photo: PhotoItem, isSensitive: (String) -> Bool) -> CLLocationCoordinate2D? {
        let names = photo.species.map { $0 as String? } + photo.dets.map { $0.name }
        let sensitive = LocationProtection.containsSensitive(names, isSensitive: isSensitive)
        guard let p = LocationProtection.protectedPosition(lat: photo.lat, lon: photo.lon, coarse: photo.coarse, sensitive: sensitive) else { return nil }
        return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
    }

    /// JPEG mit Datum, Beschreibung und genau der übergebenen Position. Ein GPS-Eintrag der Quelle wird nie übernommen:
    /// ohne Position wird er entfernt, mit Position ersetzt. Lässt sich das nicht nachweisen, wird das Bild ohne
    /// Quell-Metadaten neu kodiert; scheitert auch das, kommt bei vorhandenem Quell-GPS ein leeres Ergebnis zurück.
    static func jpegWithMetadata(_ jpeg: Data, date: Date, coordinate: CLLocationCoordinate2D?, description: String) -> Data {
        let df = DateFormatter(); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description, kCGImagePropertyTIFFSoftware: "Safari Spotter", kCGImagePropertyTIFFDateTime: df.string(from: date)],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: df.string(from: date), kCGImagePropertyExifDateTimeDigitized: df.string(from: date)]
        ]
        let gps: [CFString: Any]? = coordinate.map { c in
            [kCGImagePropertyGPSLatitude: abs(c.latitude), kCGImagePropertyGPSLatitudeRef: c.latitude < 0 ? "S" : "N",
             kCGImagePropertyGPSLongitude: abs(c.longitude), kCGImagePropertyGPSLongitudeRef: c.longitude < 0 ? "W" : "E"]
        }
        if let out = rewrite(jpeg, props: props, gps: gps, keepSource: true), gpsMatches(out, coordinate) { return out }
        if let out = rewrite(jpeg, props: props, gps: gps, keepSource: false), gpsMatches(out, coordinate) { return out }
        return gpsCoordinate(of: jpeg) == nil ? jpeg : Data()
    }

    /// GPS-Position aus den Bildinformationen eines JPEG (nil ohne GPS)
    static func gpsCoordinate(of data: Data) -> CLLocationCoordinate2D? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = (g[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (g[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        return CLLocationCoordinate2D(latitude: (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat,
                                      longitude: (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon)
    }

    /// Stimmt die geschriebene Position mit der gewünschten überein (EXIF speichert Grad als Brüche, darum ~10 m Toleranz)?
    private static func gpsMatches(_ data: Data, _ c: CLLocationCoordinate2D?) -> Bool {
        let got = gpsCoordinate(of: data)
        guard let c else { return got == nil }
        guard let got else { return false }
        return abs(got.latitude - c.latitude) < 1e-4 && abs(got.longitude - c.longitude) < 1e-4
    }

    /// Schreibt das Bild neu: `keepSource` übernimmt die komprimierten Bilddaten samt Quell-Metadaten (GPS entfernt bzw.
    /// ersetzt), sonst werden nur die Pixel neu kodiert (nur Ausrichtung der Quelle bleibt)
    private static func rewrite(_ jpeg: Data, props: [CFString: Any], gps: [CFString: Any]?, keepSource: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let type = CGImageSourceGetType(src) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type, 1, nil) else { return nil }
        var p = props
        if keepSource {
            // NSNull (= kCFNull) entfernt den GPS-Eintrag der Quelle
            if let gps { p[kCGImagePropertyGPSDictionary] = gps } else { p[kCGImagePropertyGPSDictionary] = NSNull() }
            CGImageDestinationAddImageFromSource(dest, src, 0, p as CFDictionary)
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            if let gps { p[kCGImagePropertyGPSDictionary] = gps }
            if let o = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] { p[kCGImagePropertyOrientation] = o }
            p[kCGImageDestinationLossyCompressionQuality] = 0.9
            CGImageDestinationAddImage(dest, image, p as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Recht "Fotos hinzufügen" prüfen und bei Bedarf anfragen
    static func requestAddAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        return status == .authorized || status == .limited
    }

    /// Foto mit geschützter Position, Datum und Artnamen in die Mediathek sichern
    static func export(_ photo: PhotoItem, isSensitive: (String) -> Bool) async throws {
        let coordinate = exportCoordinate(for: photo, isSensitive: isSensitive)
        let jpeg = jpegWithMetadata(photo.image, date: photo.t, coordinate: coordinate, description: "Safari Spotter: " + photo.species.joined(separator: ", "))
        guard !jpeg.isEmpty else { throw ExportError.metadata }
        guard await requestAddAccess() else { throw ExportError.denied }
        let date = photo.t
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: jpeg, options: nil)
            req.creationDate = date
            if let c = coordinate { req.location = CLLocation(latitude: c.latitude, longitude: c.longitude) }
        }
    }
}
