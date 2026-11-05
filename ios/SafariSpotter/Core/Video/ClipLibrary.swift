import Foundation
import AVFoundation
import CoreLocation
import Photos
import UIKit
import Combine

/// Liste der gespeicherten Videoclips für Galerie und Teilen. Liest die Dateien aus `ClipFiles` (Application Support/Clips).
/// Benutzung vom Hauptthread.
final class ClipLibrary: ObservableObject {
    static let shared = ClipLibrary()

    @Published private(set) var clips: [ClipRecord] = []
    let directory: URL?
    private var recoveryDone = false

    init(directory: URL? = try? ClipFiles.defaultDirectory()) {
        self.directory = directory
        reload()
    }

    func reload() {
        guard let directory else { return }
        let list = ClipFiles.list(in: directory)
        if Thread.isMainThread { clips = list } else { DispatchQueue.main.async { self.clips = list } }
    }

    func movieURL(_ clip: ClipRecord) -> URL? { directory.map { ClipFiles.movieURL(clip.id, in: $0) } }

    func thumbnail(_ clip: ClipRecord) -> UIImage? {
        guard let directory, clip.thumbnail != nil else { return nil }
        return UIImage(contentsOfFile: ClipFiles.thumbnailURL(clip.id, in: directory).path)
    }

    /// Nur auf ausdrücklichen Wunsch (Galerie, mit Rückfrage)
    func delete(_ clip: ClipRecord) throws {
        guard let directory else { return }
        try ClipFiles.delete(clip.id, in: directory)
        reload()
    }

    /// Einmal nach dem Start: Aufnahmen, die beim Beenden der App noch liefen, prüfen und als wiederhergestellt markieren
    func recoverInterrupted(excluding active: UUID?) async {
        guard !recoveryDone, let directory else { return }
        recoveryDone = true
        await ClipFiles.recoverInterrupted(in: directory, excluding: active, probe: Self.probe)
        reload()
    }

    static func probe(_ url: URL) async -> ClipProbe? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        return ClipProbe(duration: duration.seconds, width: Int(size.width), height: Int(size.height))
    }
}

/// Video in die Fotos-Mediathek. Die Datei geht unverändert mit (ohne Standort-Metadaten); als Ort bekommt der Eintrag
/// höchstens die vergröberte 10-km-Position aus der Clip-Datei, nie eine genaue.
enum VideoExporter {
    enum ExportError: LocalizedError {
        case notPlayable
        var errorDescription: String? { "Dieses Video ist beschädigt und kann nicht gesichert werden." }
    }

    static func saveToPhotos(_ clip: ClipRecord, url: URL) async throws {
        guard clip.isPlayable else { throw ExportError.notPlayable }
        guard await PhotoExporter.requestAddAccess() else { throw PhotoExporter.ExportError.denied }
        var coarseLocation: CLLocation?
        if clip.coarse, let lat = clip.lat, let lon = clip.lon { coarseLocation = CLLocation(latitude: lat, longitude: lon) }
        let location = coarseLocation, created = clip.createdAt
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false   // der Clip bleibt in der App
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = created
            request.location = location
        }
    }
}
