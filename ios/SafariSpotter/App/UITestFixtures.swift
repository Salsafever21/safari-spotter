#if DEBUG
import SwiftData
import UIKit

/// Ausschliesslich für einen expliziten UI-Teststart; öffnet oder verändert keinen persistenten Datenspeicher.
enum DriveHistoryFixture {
    static func make(corruptPhoto: Bool = false) throws -> ModelContainer {
        let container = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).jpegData(withCompressionQuality: 0.8) { canvas in
            UIColor.systemOrange.setFill()
            canvas.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        for (offset, name, key, id) in [(0.0, "Elefant", "elefant", "00000000-0000-0000-0000-000000000001"),
                                         (86400.0, "Leopard", "leopard", "00000000-0000-0000-0000-000000000002")] {
            let start = firstDate.addingTimeInterval(offset)
            let sighting = Sighting(name: name, key: key, t: start.addingTimeInterval(120),
                                    position: Position(lat: -24.9, lon: 31.5, acc: 5, coarse: false))
            context.insert(sighting)
            let photo = try PhotoItem(t: start.addingTimeInterval(120), kind: "auto", species: [name], dets: [],
                                         image: image, thumb: image, width: 80, height: 80,
                                         position: Position(lat: -24.9, lon: 31.5, acc: 5, coarse: false), sightingIds: [sighting.id])
            photo.id = UUID(uuidString: id)!
            if corruptPhoto && name == "Leopard" { photo.image = Data([0, 1, 2]) }
            context.insert(photo)
            let points = [TrackPoint(t: start.timeIntervalSince1970, lat: -24.91, lon: 31.5, spd: 4, alt: 300),
                          TrackPoint(t: start.timeIntervalSince1970 + 120, lat: -24.9, lon: 31.5, spd: 0, alt: 305),
                          TrackPoint(t: start.timeIntervalSince1970 + 240, lat: -24.9, lon: 31.5, spd: 0, alt: 305)]
            let drive = try Drive(startedAt: start, endedAt: start.addingTimeInterval(600), dist: 500, points: points, sightings: 1)
            drive.id = UUID(uuidString: id)!
            context.insert(drive)
        }
        try context.save()
        return container
    }
}
#endif
