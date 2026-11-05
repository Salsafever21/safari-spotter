import Foundation
import CryptoKit
import SwiftData

/// Writes native data in the same verified archive format as the web app.
/// It can be restored through WebBackupImporter, including on a new iPhone.
@MainActor
enum NativeBackupExporter {
    static func create(context: ModelContext, drive: DriveRecorder = .shared) throws -> URL {
        try context.save()
        let sightings = try context.fetch(FetchDescriptor<Sighting>())
        let photos = try context.fetch(FetchDescriptor<PhotoItem>())
        let corrections = try context.fetch(FetchDescriptor<Correction>())
        let drives = try context.fetch(FetchDescriptor<Drive>())
        let settings = AppSettings.shared
        let origin = "native:" + (UserDefaults.standard.string(forKey: "backupOrigin") ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "backupOrigin")
            return id
        }())
        let names = Dictionary(uniqueKeysWithValues: sightings.map { ($0.id, $0.name) })
        let sightingRecords: [[String: Any]] = sightings.map { s in
            var record: [String: Any] = ["id": s.id.uuidString, "s": s.name, "t": milliseconds(s.t),
                                          "n": s.n, "src": s.src, "coarse": s.coarse]
            record["key"] = s.key
            if let thumb = s.thumb { record["thumb"] = dataURL(thumb) }
            putPosition(&record, lat: s.lat, lon: s.lon, acc: s.acc, coarse: s.coarse,
                        sensitive: sensitive(s.name))
            return record
        }
        let driveRecords: [[String: Any]] = drives.map { d in
            ["id": d.id.uuidString, "startedAt": milliseconds(d.startedAt), "endedAt": milliseconds(d.endedAt),
             "dist": d.dist, "sightings": d.sightings,
             "points": d.points.map(pointRecord)]
        }
        let correctionRecords: [[String: Any]] = corrections.map { c in
            var record: [String: Any] = ["id": c.id.uuidString, "t": milliseconds(c.t),
                                          "img": dataURL(c.image), "status": c.status]
            record["predicted"] = c.predicted; record["predKey"] = c.predKey
            record["conf"] = c.conf; record["label"] = c.label
            record["labelKey"] = c.labelKey; record["region"] = c.region
            return record
        }
        var photoRecords: [[String: Any]] = []
        var binaryLength = 0
        for p in photos {
            var metadata: [String: Any] = ["id": p.id.uuidString, "t": milliseconds(p.t), "kind": p.kind,
                                           "species": p.species, "w": p.width, "h": p.height,
                                           "sightIds": p.sightingIds.map(\.uuidString), "coarse": p.coarse,
                                           "dets": p.dets.map { d -> [String: Any] in
                var item: [String: Any] = ["box": [d.x, d.y, d.w, d.h],
                                           "conf": d.conf, "sure": d.sure]
                item["name"] = d.name
                return item
            }]
            if let thumb = p.thumb { metadata["thumb"] = dataURL(thumb) }
            let photoSensitive = p.species.contains(where: sensitive)
                || p.dets.contains { $0.name.map(sensitive) ?? false }
                || p.sightingIds.contains { names[$0].map(sensitive) ?? false }
            putPosition(&metadata, lat: p.lat, lon: p.lon, acc: nil, coarse: p.coarse,
                        sensitive: photoSensitive)
            photoRecords.append(["metadata": metadata, "offset": binaryLength, "length": p.image.count,
                                 "type": "image/jpeg", "sha256": digest(p.image)])
            binaryLength += p.image.count
        }
        let snapshot: [String: Any] = [
            "sightings": sightingRecords, "trips": driveRecords,
            "trip": activeDrive(drive),
            "settings": ["threshold": settings.threshold, "labels": settings.labels, "far": settings.far,
                         "region": settings.region, "gps": settings.gps, "collect": settings.collect,
                         "snapshots": settings.snapshots, "autoTrack": settings.autoTrack, "res": settings.res]
        ]
        let manifest: [String: Any] = [
            "format": "safari-spotter-backup", "version": 1,
            "createdAt": ISO8601DateFormatter().string(from: .now), "sourceVersion": "ios-1.0.0",
            "origin": origin, "snapshot": snapshot, "stored": [:], "corrections": correctionRecords,
            "photos": photoRecords, "counts": ["sightings": sightings.count, "photos": photos.count,
                                                "corrections": corrections.count,
                                                "completedDrives": drives.count, "activeDrive": drive.active],
            "binaryLength": binaryLength
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest)
        let filename = "safari-spotter-ios-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))-\(UUID().uuidString).ssbackup"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: Data("SSBK1\n".utf8))
            var length = UInt64(json.count).littleEndian
            try withUnsafeBytes(of: &length) { try file.write(contentsOf: Data($0)) }
            try file.write(contentsOf: json)
            for p in photos { try file.write(contentsOf: p.image) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func milliseconds(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }
    private static func pointRecord(_ p: TrackPoint) -> [Double] {
        var record = [p.t * 1000, p.lat, p.lon, p.spd]
        if let alt = p.alt { record.append(alt) }
        return record
    }
    private static func activeDrive(_ drive: DriveRecorder) -> [String: Any] {
        guard drive.active, let start = drive.startedAt else {
            return ["active": false, "startedAt": 0, "points": [], "dist": 0]
        }
        return ["active": true, "startedAt": milliseconds(start),
                "points": drive.points.map(pointRecord), "dist": drive.dist]
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func dataURL(_ data: Data) -> String { "data:image/jpeg;base64," + data.base64EncodedString() }
    private static func sensitive(_ name: String) -> Bool {
        if SpeciesCatalog.shared.isSensitive(name: name) { return true }
        return ["rhino", "white rhino", "black rhino", "rhinoceros"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    private static func putPosition(_ record: inout [String: Any], lat: Double?, lon: Double?,
                                    acc: Double?, coarse: Bool, sensitive: Bool) {
        guard let lat, let lon else { return }
        if sensitive && !coarse {
            let pos = Position.coarsen(lat: lat, lon: lon)
            record["lat"] = pos.lat; record["lon"] = pos.lon
            record["acc"] = pos.acc; record["coarse"] = true
        } else {
            record["lat"] = lat; record["lon"] = lon
            record["acc"] = acc ?? (coarse ? 10000 : 0)
        }
    }
}
