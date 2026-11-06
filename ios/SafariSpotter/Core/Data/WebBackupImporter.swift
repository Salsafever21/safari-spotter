import Foundation
import CryptoKit
import SwiftData

/// Imports the lossless SSBK1 archive produced by the existing web app.
/// The original file is retained in Application Support even after conversion.
@MainActor
enum WebBackupImporter {
    struct Result {
        let sightings: Int
        let photos: Int
        let corrections: Int
        let drives: Int
        let archiveURL: URL
    }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): return "Sicherung ungültig: \(detail)" }
        }
    }

    static func archivedFiles() -> [URL] {
        guard let folder = try? archiveFolder(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension == "ssbackup" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func deleteArchivedFile(_ url: URL) throws {
        let folder = try archiveFolder().standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == folder,
              url.pathExtension == "ssbackup" else { throw ImportError.invalid("Archivpfad") }
        try FileManager.default.removeItem(at: url)
    }

    private static func archiveFolder() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("WebBackups", isDirectory: true)
    }

    static func perform(url: URL, context: ModelContext, archivedSource: URL? = nil,
                        retainedArchiveURL: URL? = nil) throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 14, String(data: bytes.prefix(6), encoding: .utf8) == "SSBK1\n" else {
            throw ImportError.invalid("Dateikopf")
        }
        var jsonLength: UInt64 = 0
        for i in 0..<8 { jsonLength |= UInt64(bytes[6 + i]) << (i * 8) }
        guard jsonLength > 0, jsonLength <= 100_000_000,
              jsonLength <= UInt64(bytes.count - 14) else { throw ImportError.invalid("Manifestlänge") }
        let binaryStart = 14 + Int(jsonLength)
        let raw = try JSONSerialization.jsonObject(with: bytes[14..<binaryStart])
        guard let manifest = raw as? [String: Any],
              manifest["format"] as? String == "safari-spotter-backup",
              int(manifest["version"]) == 1,
              let snapshot = manifest["snapshot"] as? [String: Any],
              let webSightings = snapshot["sightings"] as? [[String: Any]],
              let webTrips = snapshot["trips"] as? [[String: Any]],
              let webTrip = snapshot["trip"] as? [String: Any],
              let webPhotos = manifest["photos"] as? [[String: Any]],
              let webCorrections = manifest["corrections"] as? [[String: Any]],
              let counts = manifest["counts"] as? [String: Any],
              let binaryLength = int(manifest["binaryLength"]), binaryLength >= 0,
              binaryStart + binaryLength == bytes.count,
              int(counts["sightings"]) == webSightings.count,
              int(counts["photos"]) == webPhotos.count,
              int(counts["corrections"]) == webCorrections.count,
              int(counts["completedDrives"]) == webTrips.count else {
            throw ImportError.invalid("Inhalt oder Zählwerte")
        }

        // Check every JPEG before touching SwiftData. Ranges must not overlap or leave gaps.
        var cursor = 0
        for item in webPhotos {
            guard let offset = int(item["offset"]), let length = int(item["length"]),
                  offset == cursor, length >= 0, length <= binaryLength - offset,
                  let expected = item["sha256"] as? String else {
                throw ImportError.invalid("Fotobereich")
            }
            let range = (binaryStart + offset)..<(binaryStart + offset + length)
            let actual = SHA256.hash(data: bytes[range]).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw ImportError.invalid("Foto-Prüfsumme") }
            cursor += length
        }
        guard cursor == binaryLength else { throw ImportError.invalid("Fotodaten unvollständig") }

        let destination: URL
        if let retainedArchiveURL {
            guard try EncryptedBackup.isStructurallyComplete(retainedArchiveURL) else {
                throw ImportError.invalid("Archivdatei")
            }
            destination = retainedArchiveURL
        } else {
            let folder = try archiveFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archiveHash = try archivedSource.map(fileDigest)
                ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            destination = folder.appendingPathComponent("\(archiveHash)\(archivedSource == nil ? "" : "-encrypted").ssbackup")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: archivedSource ?? url, to: destination)
            }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)

        let origin = manifest["origin"] as? String ?? "unknown"
        var sightingNames: [UUID: String] = [:]
        for record in webSightings {
            if let key = record["id"], let name = record["s"] as? String {
                sightingNames[stableID(origin, "sighting", key)] = name
            }
        }
        let sightingIDs = Set(try context.fetch(FetchDescriptor<Sighting>()).map(\.id))
        let photoIDs = Set(try context.fetch(FetchDescriptor<PhotoItem>()).map(\.id))
        let correctionIDs = Set(try context.fetch(FetchDescriptor<Correction>()).map(\.id))
        let driveIDs = Set(try context.fetch(FetchDescriptor<Drive>()).map(\.id))
        var added = (sightings: 0, photos: 0, corrections: 0, drives: 0)

        do {
            for (index, record) in webSightings.enumerated() {
                let id = stableID(origin, "sighting", record["id"] ?? index)
                if sightingIDs.contains(id) { continue }
                guard let name = record["s"] as? String, let ms = number(record["t"]) else {
                    throw ImportError.invalid("Sichtung \(index + 1)")
                }
                let item = Sighting(name: name, key: record["key"] as? String,
                                    t: Date(timeIntervalSince1970: ms / 1000),
                                    n: max(0, int(record["n"]) ?? 1), position: position(record, sensitive: sensitive(name)),
                                    thumb: imageData(record["thumb"]), src: record["src"] as? String ?? "cam")
                item.id = id; context.insert(item); added.sightings += 1
            }
            for (index, entry) in webPhotos.enumerated() {
                guard let record = entry["metadata"] as? [String: Any],
                      let offset = int(entry["offset"]), let length = int(entry["length"]),
                      let ms = number(record["t"]) else { throw ImportError.invalid("Foto \(index + 1)") }
                let id = stableID(origin, "photo", record["id"] ?? index)
                if photoIDs.contains(id) { continue }
                let species = record["species"] as? [String] ?? []
                let ids = (record["sightIds"] as? [Any] ?? []).map { stableID(origin, "sighting", $0) }
                let rawDets: [[String: Any]]
                if let value = record["dets"] {
                    guard let entries = value as? [[String: Any]] else {
                        throw ImportError.invalid("Foto \(index + 1), Markierungen")
                    }
                    rawDets = entries
                } else {
                    rawDets = []
                }
                let sensitivePhoto = species.contains(where: sensitive)
                    || ids.contains { sightingNames[$0].map(sensitive) ?? false }
                    || rawDets.contains { ($0["name"] as? String).map(sensitive) ?? false }
                let image = bytes[(binaryStart + offset)..<(binaryStart + offset + length)]
                let dets = try rawDets.enumerated().map { detIndex, det -> PhotoDet in
                    guard let box = det["box"] as? [Any], box.count == 4,
                          let x = number(box[0]), let y = number(box[1]),
                          let w = number(box[2]), let h = number(box[3]),
                          x.isFinite, y.isFinite, w.isFinite, h.isFinite else {
                        throw ImportError.invalid("Foto \(index + 1), Markierung \(detIndex + 1)")
                    }
                    return PhotoDet(x: x, y: y, w: w, h: h, name: det["name"] as? String,
                                    conf: number(det["conf"]) ?? 0, sure: det["sure"] as? Bool ?? false)
                }
                let item = try PhotoItem(t: Date(timeIntervalSince1970: ms / 1000),
                                     kind: record["kind"] as? String ?? "auto", species: species, dets: dets,
                                     image: Data(image), thumb: imageData(record["thumb"]),
                                     width: int(record["w"]) ?? 0, height: int(record["h"]) ?? 0,
                                     position: position(record, sensitive: sensitivePhoto), sightingIds: ids)
                item.id = id; context.insert(item); added.photos += 1
            }
            for (index, record) in webCorrections.enumerated() {
                let id = stableID(origin, "correction", record["id"] ?? index)
                if correctionIDs.contains(id) { continue }
                guard let image = imageData(record["img"]) else { throw ImportError.invalid("Korrekturbild \(index + 1)") }
                let item = Correction(image: image, predicted: record["predicted"] as? String,
                                      predKey: record["predKey"] as? String, conf: number(record["conf"]),
                                      label: record["label"] as? String, labelKey: record["labelKey"] as? String,
                                      status: record["status"] as? String ?? "review", region: record["region"] as? String)
                item.id = id
                if let ms = number(record["t"]) { item.t = Date(timeIntervalSince1970: ms / 1000) }
                context.insert(item); added.corrections += 1
            }
            var drives = webTrips
            if webTrip["active"] as? Bool == true { // Preserve the route visible as a completed import snapshot.
                var frozen = webTrip
                let iso = ISO8601DateFormatter()
                let backupTime = iso.date(from: manifest["createdAt"] as? String ?? "")?.timeIntervalSince1970
                    ?? Date().timeIntervalSince1970
                frozen["endedAt"] = backupTime * 1000
                drives.append(frozen)
            }
            for (index, record) in drives.enumerated() {
                let id = stableID(origin, "drive", record["id"] ?? record["startedAt"] ?? index)
                if driveIDs.contains(id) { continue }
                guard let start = number(record["startedAt"]), let end = number(record["endedAt"]) else {
                    throw ImportError.invalid("Game Drive \(index + 1)")
                }
                let rawPoints: [[Any]]
                if let value = record["points"] {
                    guard let entries = value as? [[Any]] else {
                        throw ImportError.invalid("Game Drive \(index + 1), Fahrtspur")
                    }
                    rawPoints = entries
                } else {
                    rawPoints = []
                }
                let points = try rawPoints.enumerated().map { pointIndex, p -> TrackPoint in
                    guard p.count >= 4, let t = number(p[0]), let lat = number(p[1]),
                          let lon = number(p[2]), let speed = number(p[3]),
                          t.isFinite, lat.isFinite, lon.isFinite, speed.isFinite,
                          p.count <= 4 || p[4] is NSNull || number(p[4])?.isFinite == true else {
                        throw ImportError.invalid("Game Drive \(index + 1), Punkt \(pointIndex + 1)")
                    }
                    return TrackPoint(t: t / 1000, lat: lat, lon: lon, spd: speed,
                                      alt: p.count > 4 ? number(p[4]) : nil)
                }
                let item = try Drive(startedAt: Date(timeIntervalSince1970: start / 1000),
                                 endedAt: Date(timeIntervalSince1970: end / 1000),
                                 dist: number(record["dist"]) ?? 0, points: points,
                                 sightings: int(record["sightings"]) ?? 0)
                item.id = id; context.insert(item); added.drives += 1
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        if let webSettings = snapshot["settings"] as? [String: Any] { applySettings(webSettings) }
        return Result(sightings: added.sightings, photos: added.photos, corrections: added.corrections,
                      drives: added.drives, archiveURL: destination)
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func fileDigest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let part = try input.read(upToCount: 1_048_576), !part.isEmpty { hash.update(data: part) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func sensitive(_ name: String) -> Bool {
        if SpeciesCatalog.shared.isSensitive(name: name) { return true }
        return ["rhino", "white rhino", "black rhino", "rhinoceros"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    private static func position(_ value: [String: Any], sensitive: Bool) -> Position? {
        guard let lat = number(value["lat"]), let lon = number(value["lon"]) else { return nil }
        if sensitive && value["coarse"] as? Bool != true { return Position.coarsen(lat: lat, lon: lon) }
        return Position(lat: lat, lon: lon, acc: number(value["acc"]) ?? 0, coarse: value["coarse"] as? Bool ?? false)
    }
    private static func imageData(_ value: Any?) -> Data? {
        guard let text = value as? String, let comma = text.firstIndex(of: ","),
              text[..<comma].contains("base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }
    private static func stableID(_ origin: String, _ kind: String, _ value: Any) -> UUID {
        if origin.hasPrefix("native:"), let text = value as? String, let id = UUID(uuidString: text) { return id }
        let data = Data("\(origin)/\(kind)/\(value)".utf8)
        var hash = Array(SHA256.hash(data: data).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
    private static func applySettings(_ value: [String: Any]) {
        let settings = AppSettings.shared
        if let v = number(value["threshold"]) { settings.threshold = v }
        if let v = value["labels"] as? Bool { settings.labels = v }
        if let v = value["far"] as? String { settings.far = v }
        if let v = value["region"] as? String { settings.region = v }
        if let v = value["gps"] as? Bool { settings.gps = v }
        if let v = value["collect"] as? Bool { settings.collect = v }
        if let v = value["snapshots"] as? Bool { settings.snapshots = v }
        if let v = value["autoTrack"] as? Bool { settings.autoTrack = v }
        if let v = value["res"] as? String { settings.res = v }
        if let v = value["lensID"] as? String { settings.lensID = v }
        if let v = value["burnIn"] as? Bool { settings.burnIn = v }
        if let v = value["originCountry"] as? String { settings.originCountry = v }
        if let v = value["destinationCountry"] as? String { settings.destinationCountry = v }
        if let v = value["onboardingComplete"] as? Bool { settings.onboardingComplete = v }
    }
}
