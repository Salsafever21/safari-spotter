import Foundation
import SwiftData
import CoreLocation

/// Sichtung (ss.sightings)
@Model
final class Sighting {
    @Attribute(.unique) var id: UUID
    var name: String
    var key: String?
    var t: Date
    var n: Int
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var coarse: Bool
    var thumb: Data?
    var src: String   // cam | hint | photo | manual

    init(name: String, key: String?, t: Date = .now, n: Int = 1, position: Position? = nil, thumb: Data? = nil, src: String = "cam") {
        id = UUID(); self.name = name; self.key = key; self.t = t; self.n = n
        lat = position?.lat; lon = position?.lon; acc = position?.acc; coarse = position?.coarse ?? false
        self.thumb = thumb; self.src = src
    }
    var coordinate: CLLocationCoordinate2D? { guard let lat, let lon else { return nil }; return .init(latitude: lat, longitude: lon) }
}

/// Foto (Schnappschuss bei Erkennung, Foto-Modus, Mediathek)
@Model
final class PhotoItem {
    @Attribute(.unique) var id: UUID
    var t: Date
    var kind: String            // auto | cam | photo
    var species: [String]
    var detsJSON: Data?         // [[x,y,w,h,name,conf,sure]] in Bildkoordinaten
    @Attribute(.externalStorage) var image: Data
    var thumb: Data?
    var width: Int
    var height: Int
    var lat: Double?
    var lon: Double?
    var coarse: Bool
    var sightingIds: [UUID]

    init(t: Date, kind: String, species: [String], dets: [PhotoDet], image: Data, thumb: Data?, width: Int, height: Int, position: Position?, sightingIds: [UUID]) {
        id = UUID(); self.t = t; self.kind = kind; self.species = species
        detsJSON = try? JSONEncoder().encode(dets)
        self.image = image; self.thumb = thumb; self.width = width; self.height = height
        lat = position?.lat; lon = position?.lon; coarse = position?.coarse ?? false; self.sightingIds = sightingIds
    }
    var dets: [PhotoDet] { detsJSON.flatMap { try? JSONDecoder().decode([PhotoDet].self, from: $0) } ?? [] }
    var coordinate: CLLocationCoordinate2D? { guard let lat, let lon else { return nil }; return .init(latitude: lat, longitude: lon) }
}

struct PhotoDet: Codable { var x: Double; var y: Double; var w: Double; var h: Double; var name: String?; var conf: Double; var sure: Bool }

/// Korrektur / Prüfliste (IndexedDB corrections)
@Model
final class Correction {
    @Attribute(.unique) var id: UUID
    var t: Date
    @Attribute(.externalStorage) var image: Data   // 224-px-Ausschnitt
    var predicted: String?
    var predKey: String?
    var conf: Double?
    var label: String?
    var labelKey: String?
    var status: String   // review | confirmed | corrected
    var region: String?

    init(image: Data, predicted: String?, predKey: String?, conf: Double?, label: String? = nil, labelKey: String? = nil, status: String, region: String?) {
        id = UUID(); t = .now; self.image = image; self.predicted = predicted; self.predKey = predKey; self.conf = conf
        self.label = label; self.labelKey = labelKey; self.status = status; self.region = region
    }
}

/// Abgeschlossener Game Drive (ss.trips)
@Model
final class Drive {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date
    var dist: Double
    var pointsJSON: Data     // [[t, lat, lon, speed, alt]]
    var sightings: Int

    init(startedAt: Date, endedAt: Date, dist: Double, points: [TrackPoint], sightings: Int) {
        id = UUID(); self.startedAt = startedAt; self.endedAt = endedAt; self.dist = dist
        pointsJSON = (try? JSONEncoder().encode(points)) ?? Data(); self.sightings = sightings
    }
    var points: [TrackPoint] { (try? JSONDecoder().decode([TrackPoint].self, from: pointsJSON)) ?? [] }
}

/// Position einer Sichtung, bei Nashörnern bereits vergröbert
struct Position: Codable {
    var lat: Double
    var lon: Double
    var acc: Double
    var coarse: Bool

    /// Artenschutz: Standort auf ein 10-km-Raster (Zellenmitte), identisch zu coarsen() im Web
    static func coarsen(lat: Double, lon: Double) -> Position {
        let cell = 10000.0 / 111320.0
        let cellLon = cell / max(0.2, cos(lat * .pi / 180))
        return Position(lat: (floor(lat / cell) + 0.5) * cell, lon: (floor(lon / cellLon) + 0.5) * cellLon, acc: 10000, coarse: true)
    }
    static func from(_ loc: CLLocation, sensitive: Bool) -> Position {
        if sensitive { return coarsen(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude) }
        return Position(lat: (loc.coordinate.latitude * 1e5).rounded() / 1e5, lon: (loc.coordinate.longitude * 1e5).rounded() / 1e5, acc: loc.horizontalAccuracy.rounded(), coarse: false)
    }
}
