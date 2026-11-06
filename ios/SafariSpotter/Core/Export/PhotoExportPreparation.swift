import Foundation
import CoreLocation
import ImageIO

extension PhotoExporter {
    /// Nur kopierte Werte verlassen den Main Actor; SwiftData-Objekte und Katalog bleiben auf ihrem Actor.
    struct ImageSnapshot: Sendable {
        let image: Data
        let date: Date
        let latitude: Double?
        let longitude: Double?
        let description: String
        let stripSourceMetadata: Bool

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct PreparedPhoto: Sendable {
        let jpeg: Data
        let date: Date
        let latitude: Double?
        let longitude: Double?
    }

    typealias ImageProcessor = @Sendable (ImageSnapshot) throws -> PreparedPhoto

    @MainActor
    static func snapshot(_ photo: PhotoItem, isSensitive: (String) -> Bool,
                         protectedTimes: [TimeInterval]) -> ImageSnapshot {
        let coordinate = exportCoordinate(for: photo, isSensitive: isSensitive, protectedTimes: protectedTimes)
        return ImageSnapshot(image: photo.image,
            date: exportDate(for: photo, isSensitive: isSensitive, protectedTimes: protectedTimes),
            latitude: coordinate?.latitude, longitude: coordinate?.longitude,
            description: "Safari Spotter: " + photo.species.joined(separator: ", "),
            stripSourceMetadata: requiresProtection(for: photo, isSensitive: isSensitive, protectedTimes: protectedTimes))
    }

    /// Pro Bild eine Verarbeitung; nach dem Autorelease-Pool bleiben nur komprimierte Daten für die Mediathek übrig.
    static func prepareInBackground(_ snapshot: ImageSnapshot,
                                    process: @escaping ImageProcessor = { try prepare($0) }) async throws -> PreparedPhoto {
        try Task.checkCancellation()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool { try process(snapshot) }
        }.value
        try Task.checkCancellation()
        return prepared
    }

    static func prepare(_ snapshot: ImageSnapshot) throws -> PreparedPhoto {
        let jpeg = jpegWithMetadata(snapshot.image, date: snapshot.date, coordinate: snapshot.coordinate,
                                    description: snapshot.description, stripSourceMetadata: snapshot.stripSourceMetadata)
        guard !jpeg.isEmpty else { throw ExportError.metadata }
        // Auch der Metadaten-Rückfall darf keine unlesbaren Bytes an Fotos weiterreichen. Sofort dekodieren;
        // das vermeidet eine irreführende Berechtigungsfrage oder einen erst später auftretenden Schreibfehler.
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
        else { throw ExportError.invalidImage }
        return PreparedPhoto(jpeg: jpeg, date: snapshot.date, latitude: snapshot.latitude, longitude: snapshot.longitude)
    }
}
