import Foundation
import CoreLocation
import Photos
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import CryptoKit

/// Exporte mit Artenschutz: Nashorn-Sichtungen nur mit 10-km-Raster und auf die Stunde gerundeter Zeit, Spur ±15 min ausgeblendet.
enum Exporters {
    static func hourFloor(_ d: Date) -> Date { Date(timeIntervalSince1970: floor(d.timeIntervalSince1970 / 3600) * 3600) }

    private static func csvField(_ value: String, literalText: Bool = false) -> String {
        var text = value
        if literalText, let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
           "=+-@".contains(first) { text = "'" + text }
        if text.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    private static func protectedTimes(sightings: [Sighting], photos: [PhotoItem], catalog: SpeciesCatalog) -> [TimeInterval] {
        sightings.filter { $0.coarse || catalog.isSensitive(name: $0.name) }.map { $0.t.timeIntervalSince1970 }
        + photos.filter { PhotoExporter.requiresProtection(for: $0, isSensitive: catalog.isSensitive) }.map { $0.t.timeIntervalSince1970 }
    }

    static func csv(sightings: [Sighting], catalog: SpeciesCatalog,
                    privacySightings: [Sighting]? = nil, privacyPhotos: [PhotoItem] = []) -> String {
        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"; let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let protected = protectedTimes(sightings: privacySightings ?? sightings, photos: privacyPhotos, catalog: catalog)
        var rows = ["Datum;Zeit;Art;Anzahl;Breite;Laenge;Genauigkeit"]
        for s in sightings {
            let sens = s.coarse || catalog.isSensitive(name: s.name) || protected.contains { abs(s.t.timeIntervalSince1970 - $0) <= 15 * 60 }
            let position = LocationProtection.protectedPosition(lat: s.lat, lon: s.lon, coarse: s.coarse, sensitive: sens)
            let t = sens ? hourFloor(s.t) : s.t
            let prec = position == nil ? "" : sens ? "±10 km (Artenschutz)" : "±\(Int(s.acc ?? 0)) m"
            let lat = position.map { String(format: sens ? "%.2f" : "%.5f", $0.lat) } ?? "", lon = position.map { String(format: sens ? "%.2f" : "%.5f", $0.lon) } ?? ""
            rows.append([csvField(df.string(from: t)), csvField(tf.string(from: t) + (sens ? " (gerundet)" : "")),
                         csvField(s.name, literalText: true), String(s.n), lat, lon, csvField(prec)].joined(separator: ";"))
        }
        return "\u{FEFF}" + rows.joined(separator: "\n")
    }

    static func gpx(points: [TrackPoint], sightings: [Sighting], catalog: SpeciesCatalog, version: String,
                    privacySightings: [Sighting]? = nil, privacyPhotos: [PhotoItem] = []) -> String {
        let iso = ISO8601DateFormatter()
        let sensTimes = protectedTimes(sightings: privacySightings ?? sightings, photos: privacyPhotos, catalog: catalog)
        func hidden(_ t: TimeInterval) -> Bool { sensTimes.contains { abs(t - $0) <= 15 * 60 } }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var g = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Safari Spotter iOS \(version)\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        for s in sightings {
            let sens = s.coarse || catalog.isSensitive(name: s.name) || hidden(s.t.timeIntervalSince1970)
            guard let position = LocationProtection.protectedPosition(lat: s.lat, lon: s.lon, coarse: s.coarse, sensitive: sens) else { continue }
            let t = sens ? hourFloor(s.t) : s.t
            g += "  <wpt lat=\"\(String(format: sens ? "%.3f" : "%.5f", position.lat))\" lon=\"\(String(format: sens ? "%.3f" : "%.5f", position.lon))\"><time>\(iso.string(from: t))</time><name>\(esc(s.name))\(s.n > 1 ? " (\(s.n))" : "")</name><desc>\(sens ? "±10 km (Artenschutz)" : "±\(Int(s.acc ?? 0)) m")</desc></wpt>\n"
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

}

/// Creates a stable snapshot of reviewed classifier crops only when the user exports them.
@MainActor
enum CorrectionExporter {
    private static let prefix = "safari-spotter-korrekturen-"
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    enum ExportError: LocalizedError {
        case empty, invalidImage
        var errorDescription: String? {
            switch self {
            case .empty: return "Keine geprüften Korrekturen zum Exportieren vorhanden."
            case .invalidImage: return "Ein Korrekturbild konnte nicht ohne Metadaten exportiert werden."
            }
        }
    }

    static func create(_ corrections: [Correction],
                       directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !corrections.isEmpty else { throw ExportError.empty }
        let items: [[String: Any]] = try corrections.map { c in
            ["img": "data:image/jpeg;base64," + (try jpegWithoutMetadata(c.image)).base64EncodedString(),
             // Links an iOS export to the same original JPEG in a web export without exposing that JPEG.
             "sourceJPEGHash": SHA256.hash(data: c.image).map { String(format: "%02x", $0) }.joined(),
             "predicted": c.predicted ?? NSNull(), "predKey": c.predKey ?? NSNull(),
             "conf": c.conf ?? NSNull(), "label": c.label ?? NSNull(),
             "labelKey": c.labelKey ?? NSNull(), "status": c.status,
             "t": c.t.timeIntervalSince1970 * 1000, "region": c.region ?? NSNull()]
        }
        let exportedAt = ISO8601DateFormatter()
        exportedAt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = ["app": "Safari Spotter iOS",
                                      "exported": exportedAt.string(from: .now),
                                      "items": items]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let url = directory.appendingPathComponent("\(prefix)\(UUID().uuidString).json")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func jpegWithoutMetadata(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExportError.invalidImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: pixels).oriented(forExifOrientation: orientation)
        let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                               y: -image.extent.minY))
        guard let jpeg = imageContext.jpegRepresentation(of: upright, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
        else { throw ExportError.invalidImage }
        return jpeg
    }

    /// Removes only this exporter's abandoned temporary files; a current share remains untouched.
    static func removeStale(in directory: URL = FileManager.default.temporaryDirectory,
                            before cutoff: Date = Date().addingTimeInterval(-3600)) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let changed = values.contentModificationDate, changed < cutoff else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// Fotos-App: Bild mit Aufnahmedatum, Standort und Beschreibung (EXIF/TIFF) sichern, so erscheint es auf der Orte-Karte.
/// Artenschutz: Die Position, mit der ein Foto die App verlässt, kommt immer aus `exportCoordinate` (zweite Absicherung,
/// greift auch bei Fotos, die vor dieser Regel oder per Import gespeichert wurden).
enum PhotoExporter {
    static func requiresProtection(for photo: PhotoItem, isSensitive: (String) -> Bool) -> Bool {
        photo.coarse || LocationProtection.containsSensitive(photo.species.map { $0 as String? } + photo.dets.map(\.name),
                                                            isSensitive: isSensitive)
    }

    static func exportDate(for photo: PhotoItem, isSensitive: (String) -> Bool) -> Date {
        requiresProtection(for: photo, isSensitive: isSensitive) ? Exporters.hourFloor(photo.t) : photo.t
    }

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
    static func jpegWithMetadata(_ jpeg: Data, date: Date, coordinate: CLLocationCoordinate2D?, description: String,
                                 stripSourceMetadata: Bool = false) -> Data {
        let df = DateFormatter(); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description, kCGImagePropertyTIFFSoftware: "Safari Spotter", kCGImagePropertyTIFFDateTime: df.string(from: date)],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: df.string(from: date), kCGImagePropertyExifDateTimeDigitized: df.string(from: date)]
        ]
        let gps: [CFString: Any]? = coordinate.map { c in
            [kCGImagePropertyGPSLatitude: abs(c.latitude), kCGImagePropertyGPSLatitudeRef: c.latitude < 0 ? "S" : "N",
             kCGImagePropertyGPSLongitude: abs(c.longitude), kCGImagePropertyGPSLongitudeRef: c.longitude < 0 ? "W" : "E"]
        }
        if !stripSourceMetadata, let out = rewrite(jpeg, props: props, gps: gps, keepSource: true), gpsMatches(out, coordinate) { return out }
        if let out = rewrite(jpeg, props: props, gps: gps, keepSource: false), gpsMatches(out, coordinate) { return out }
        return !stripSourceMetadata && gpsCoordinate(of: jpeg) == nil ? jpeg : Data()
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
        let date = exportDate(for: photo, isSensitive: isSensitive)
        let jpeg = jpegWithMetadata(photo.image, date: date, coordinate: coordinate, description: "Safari Spotter: " + photo.species.joined(separator: ", "),
                                    stripSourceMetadata: requiresProtection(for: photo, isSensitive: isSensitive))
        guard !jpeg.isEmpty else { throw ExportError.metadata }
        guard await requestAddAccess() else { throw ExportError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: jpeg, options: nil)
            req.creationDate = date
            if let c = coordinate { req.location = CLLocation(latitude: c.latitude, longitude: c.longitude) }
        }
    }
}
