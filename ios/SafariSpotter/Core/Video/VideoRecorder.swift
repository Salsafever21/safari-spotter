import Foundation
import AVFoundation
import CoreImage
import CoreMedia

/// Videoaufnahme, unabhängig von der Tiererkennung.
///
/// Die Kamera gibt jedes Bild über `append` weiter (Bild-Queue, kehrt sofort zurück). Geschrieben wird auf einer eigenen
/// Queue mit `AVAssetWriter`; die langsame Erkennung läuft woanders und kann hier nichts aufhalten. Rahmen kommen über
/// `updateOverlay` aus der Erkennung und werden auf Wunsch ins Bild eingebrannt.
///
/// Datei: QuickTime `.mov`, HEVC (sonst H.264), höchstens Full HD, mit optionalem Mikrofonton, mit Fragmenten je Sekunde (nach einem Absturz
/// bis zur letzten Sekunde lesbar). Metadaten nur Erstellungsdatum und Software, **nie ein Standort**.
final class VideoRecorder {
    struct StartInfo {
        var id = UUID()
        var createdAt = Date()
        var directory: URL
        var burnIn: Bool
        var labels: Bool
        var position: Position?      // muss bereits vergröbert sein; landet nur in der JSON-Datei, nie im Video
        var lens: String?
        var trackingActive: Bool
        var includeAudio = false
        var stamp: String?           // "Safari Spotter · 05.11.2026 14:03", nur bei eingebrannten Rahmen
    }

    enum StopReason: Equatable { case user, background, interrupted, thermal, lowStorage, failed(String) }

    enum RecorderError: LocalizedError {
        case setup(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .setup(let d): return "Aufnahme konnte nicht starten: \(d)"
            case .failed(let d): return "Aufnahme abgebrochen: \(d)"
            }
        }
    }

    /// Auf dem Hauptthread, wenn der Schreiber selbst beenden muss (Schreibfehler, Speicher knapp)
    var onAutoStop: ((StopReason) -> Void)?
    /// Artenschutz-Prüfung für `ClipRecord.sensitive` (SpeciesCatalog ist nach dem Laden unveränderlich, also thread-sicher)
    var isSensitive: (String) -> Bool = { _ in false }

    /// Höchstens so viele Bilder warten auf das Schreiben; darüber wird verworfen und gezählt, statt den Kamera-Pool leerzusaugen
    static let maxPendingFrames = 6

    private let writerQueue = DispatchQueue(label: "ch.solution21.safarispotter.video", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    // geschützt durch `lock`
    private var accepting = false
    private var pending = 0
    private var skipped = 0
    private var droppedByCamera = 0
    private var overlayTracks: [CameraController.TrackSnapshot] = []
    private var overlayFrameSize: CGSize = .zero
    private var overlayVersion = 0
    private var seenSpecies = Set<String>()
    private var sightingIds: [UUID] = []
    // nur auf `writerQueue`
    private var current: Recording?
    private var storageTimer: DispatchSourceTimer?

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return accepting }

    // MARK: Start und Stopp (Hauptthread)

    func start(_ info: StartInfo) {
        lock.lock(); skipped = 0; droppedByCamera = 0; seenSpecies = []; sightingIds = []; lock.unlock()
        writerQueue.async {
            self.current = Recording(info: info)
            self.startStorageWatch(directory: info.directory)
        }
        // erst danach Bilder annehmen: die serielle Queue bearbeitet sie garantiert nach dem Anlegen
        lock.lock(); accepting = true; lock.unlock()
    }

    /// Beendet die Aufnahme. Bilder, die schon unterwegs sind, werden noch geschrieben. `completion` auf dem Hauptthread:
    /// `.success(nil)`, wenn kein einziges Bild ankam.
    func stop(reason: StopReason, completion: @escaping (Result<ClipRecord?, Error>) -> Void) {
        lock.lock()
        accepting = false
        let notes = Notes(species: Array(seenSpecies).sorted(), sightingIds: sightingIds, dropped: droppedByCamera + skipped)
        lock.unlock()
        writerQueue.async {
            self.stopStorageWatch()
            guard let rec = self.current else { DispatchQueue.main.async { completion(.success(nil)) }; return }
            self.current = nil
            self.finish(rec, notes: notes) { result in DispatchQueue.main.async { completion(result) } }
        }
    }

    // MARK: Bilder (Bild-Queue der Kamera, muss sofort zurückkehren)

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < Self.maxPendingFrames else { skipped += 1; lock.unlock(); return }
        pending += 1
        lock.unlock()
        writerQueue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            self.write(sampleBuffer)
        }
    }

    /// Mikrofonpuffer gehen auf dieselbe Schreib-Queue wie die Videobilder; bis zum ersten Videobild werden sie verworfen.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); let allowed = accepting; lock.unlock()
        guard allowed else { return }
        writerQueue.async { self.writeAudio(sampleBuffer) }
    }

    /// Von `captureOutput(_:didDrop:from:)`: die Kamera hat ein Bild verworfen
    func noteDroppedFrame() {
        lock.lock(); if accepting { droppedByCamera += 1 }; lock.unlock()
    }

    // MARK: Rahmen und Sichtungen

    /// Aktuelle Rahmen aus der Erkennung (beliebiger Thread). `frameSize` ist die Grösse des Kamerabilds, zu dem sie gehören.
    func updateOverlay(_ tracks: [CameraController.TrackSnapshot], frameSize: CGSize) {
        lock.lock()
        overlayTracks = tracks; overlayFrameSize = frameSize; overlayVersion &+= 1
        if accepting { for t in tracks where t.sure { seenSpecies.insert(t.name) } }
        lock.unlock()
    }

    func clearOverlay() { updateOverlay([], frameSize: .zero) }

    /// Eine Sichtung entstand oder wurde gezählt, während die Aufnahme lief
    func noteSighting(id: UUID, name: String) {
        lock.lock()
        if accepting { if !sightingIds.contains(id) { sightingIds.append(id) }; seenSpecies.insert(name) }
        lock.unlock()
    }

    // MARK: Schreiben (writerQueue)

    private struct Notes { var species: [String]; var sightingIds: [UUID]; var dropped: Int }

    private final class Recording {
        let info: StartInfo
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var outputSize: CGSize = .zero
        var codec = ""
        var firstPTS: CMTime = .invalid
        var lastPTS: CMTime = .invalid
        var frames = 0
        var lost = 0                 // Schreiber nicht bereit oder Fehler beim Anhängen
        var failure: String?
        var overlayVersion = -1
        var overlayImage: CIImage?
        var hasThumbnail = false
        var savedInitialRecord = false
        init(info: StartInfo) { self.info = info }
    }

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard let rec = current, rec.failure == nil, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        if rec.writer == nil {
            do { try setUpWriter(rec, firstFrame: pb, at: pts) }
            catch { fail(rec, error.localizedDescription); return }
        }
        guard let writer = rec.writer, let input = rec.input, let adaptor = rec.adaptor else { return }
        guard writer.status == .writing else { fail(rec, writer.error?.localizedDescription ?? "Schreiber gestoppt"); return }
        if rec.lastPTS.isValid && CMTimeCompare(pts, rec.lastPTS) <= 0 { return }   // nur streng steigende Zeitstempel
        guard input.isReadyForMoreMediaData else { rec.lost += 1; return }
        let frame = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let out: CVPixelBuffer
        if !rec.info.burnIn && frame == rec.outputSize {
            out = pb   // durchreichen, ohne neu zu zeichnen
        } else if let rendered = render(pb, frame: frame, rec, pool: adaptor.pixelBufferPool) {
            out = rendered
        } else { rec.lost += 1; return }
        if adaptor.append(out, withPresentationTime: pts) {
            rec.frames += 1; rec.lastPTS = pts
        } else {
            rec.lost += 1
            if writer.status == .failed { fail(rec, writer.error?.localizedDescription ?? "Schreibfehler"); return }
        }
        if !rec.savedInitialRecord {
            // Vorschaubild und Metadaten im Zustand "recording": nach einem Absturz findet die App den Clip wieder
            rec.savedInitialRecord = true
            writeThumbnail(out, rec)
            try? ClipFiles.save(record(rec, notes: Notes(species: [], sightingIds: [], dropped: 0), state: .recording), in: rec.info.directory)
        }
    }

    private func writeAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let rec = current, rec.info.includeAudio, rec.firstPTS.isValid,
              let writer = rec.writer, writer.status == .writing,
              let input = rec.audioInput, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, CMTimeCompare(pts, rec.firstPTS) >= 0 else { return }
        if !input.append(sampleBuffer), writer.status == .failed {
            fail(rec, writer.error?.localizedDescription ?? "Tonspur konnte nicht geschrieben werden")
        }
    }

    private func setUpWriter(_ rec: Recording, firstFrame pb: CVPixelBuffer, at pts: CMTime) throws {
        let frame = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let size = VideoGeometry.outputSize(for: frame)
        guard size.width > 0, size.height > 0 else { throw RecorderError.setup("Bildgrösse") }
        try FileManager.default.createDirectory(at: rec.info.directory, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: ClipFiles.movieURL(rec.info.id, in: rec.info.directory), fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.metadata = Self.metadata(createdAt: rec.info.createdAt)
        var settings = Self.videoSettings(size: size, hevc: true), codec = "hvc1"
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { settings = Self.videoSettings(size: size, hevc: false); codec = "avc1" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: Int(size.width),
                                         kCVPixelBufferHeightKey as String: Int(size.height),
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw RecorderError.setup("Videospur") }
        writer.add(input)
        if rec.info.includeAudio {
            let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                AVSampleRateKey: 44_100,
                                                AVNumberOfChannelsKey: 1,
                                                AVEncoderBitRateKey: 64_000]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { throw RecorderError.setup("Tonspur") }
            writer.add(audioInput)
            rec.audioInput = audioInput
        }
        guard writer.startWriting() else { throw writer.error ?? RecorderError.setup("Schreiber") }
        writer.startSession(atSourceTime: pts)
        rec.writer = writer; rec.input = input; rec.adaptor = adaptor
        rec.outputSize = size; rec.codec = codec; rec.firstPTS = pts
    }

    /// Kamerabild auf die Ausgabegrösse bringen und bei Bedarf Rahmen, Namen und Zeitstempel darüberlegen
    private func render(_ pb: CVPixelBuffer, frame: CGSize, _ rec: Recording, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let dst = target else { return nil }
        var image = CIImage(cvPixelBuffer: pb)
        if frame != rec.outputSize {
            image = image.transformed(by: CGAffineTransform(scaleX: rec.outputSize.width / frame.width, y: rec.outputSize.height / frame.height))
        }
        if rec.info.burnIn, let overlay = overlayImage(rec, frame: frame) { image = overlay.composited(over: image) }
        ciContext.render(image, to: dst, bounds: CGRect(origin: .zero, size: rec.outputSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return dst
    }

    /// Overlay nur neu zeichnen, wenn die Erkennung neue Rahmen geliefert hat (rund 10-mal pro Sekunde, nicht 30-mal)
    private func overlayImage(_ rec: Recording, frame: CGSize) -> CIImage? {
        lock.lock(); let version = overlayVersion, tracks = overlayTracks, size = overlayFrameSize; lock.unlock()
        if version != rec.overlayVersion {
            rec.overlayVersion = version
            // Rahmen gehören zu einem Kamerabild genau dieser Grösse; passen sie nicht, lieber keine als verschobene
            let usable = size == frame ? tracks : []
            rec.overlayImage = VideoOverlayRenderer.image(tracks: usable, frameSize: frame, output: rec.outputSize,
                                                          labels: rec.info.labels, stamp: rec.info.stamp).map { CIImage(cgImage: $0) }
        }
        return rec.overlayImage
    }

    private func writeThumbnail(_ pb: CVPixelBuffer, _ rec: Recording) {
        let image = CIImage(cvPixelBuffer: pb)
        let k = min(1, 480 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: scaled, colorSpace: space,
                                                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7])
        else { return }
        rec.hasThumbnail = (try? jpeg.write(to: ClipFiles.thumbnailURL(rec.info.id, in: rec.info.directory), options: .atomic)) != nil
    }

    private func fail(_ rec: Recording, _ message: String) {
        guard rec.failure == nil else { return }
        rec.failure = message
        lock.lock(); accepting = false; lock.unlock()
        DispatchQueue.main.async { self.onAutoStop?(.failed(message)) }
    }

    private func finish(_ rec: Recording, notes: Notes, completion: @escaping (Result<ClipRecord?, Error>) -> Void) {
        guard let writer = rec.writer, let input = rec.input, rec.frames > 0 else {
            // Kein einziges Bild: nichts behalten (es sind nur Dateien dieser neuen, leeren Aufnahme)
            rec.writer?.cancelWriting()
            try? ClipFiles.delete(rec.info.id, in: rec.info.directory)
            if let failure = rec.failure { completion(.failure(RecorderError.failed(failure))) } else { completion(.success(nil)) }
            return
        }
        guard writer.status == .writing else {
            completion(finalize(rec, notes: notes, state: .damaged)); return
        }
        input.markAsFinished()
        rec.audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(rec.lastPTS, frameDuration(rec)))
        writer.finishWriting {
            self.writerQueue.async {
                completion(self.finalize(rec, notes: notes, state: writer.status == .completed ? .complete : .damaged))
            }
        }
    }

    private func finalize(_ rec: Recording, notes: Notes, state: ClipRecord.State) -> Result<ClipRecord?, Error> {
        let r = record(rec, notes: notes, state: state)
        do { try ClipFiles.save(r, in: rec.info.directory); return .success(r) }
        catch { return .failure(error) }
    }

    private func frameDuration(_ rec: Recording) -> CMTime {
        guard rec.frames > 1, rec.firstPTS.isValid, rec.lastPTS.isValid else { return CMTime(value: 1, timescale: 30) }
        let span = CMTimeSubtract(rec.lastPTS, rec.firstPTS)
        return CMTimeMultiplyByRatio(span, multiplier: 1, divisor: Int32(rec.frames - 1))
    }

    private func record(_ rec: Recording, notes: Notes, state: ClipRecord.State) -> ClipRecord {
        let id = rec.info.id
        var r = ClipRecord(id: id, createdAt: rec.info.createdAt, burnedIn: rec.info.burnIn, trackingActive: rec.info.trackingActive, state: state)
        if rec.firstPTS.isValid && rec.lastPTS.isValid {
            r.duration = CMTimeSubtract(rec.lastPTS, rec.firstPTS).seconds + frameDuration(rec).seconds
        }
        r.width = Int(rec.outputSize.width); r.height = Int(rec.outputSize.height); r.codec = rec.codec
        r.frames = rec.frames
        r.droppedFrames = notes.dropped + rec.lost
        r.species = notes.species
        r.sightingIds = notes.sightingIds
        r.sensitive = notes.species.contains(where: isSensitive)
        if let p = rec.info.position { r.lat = p.lat; r.lon = p.lon; r.coarse = true }
        r.lens = rec.info.lens
        r.thumbnail = rec.hasThumbnail ? ClipFiles.thumbnailName(id) : nil
        r.fileSize = ClipFiles.fileSize(ClipFiles.movieURL(id, in: rec.info.directory))
        return r
    }

    // MARK: Speicherplatz (writerQueue)

    private func startStorageWatch(directory: URL) {
        stopStorageWatch()
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.current != nil else { return }
            let free = ClipFiles.availableCapacity(at: directory)
            guard !ClipFiles.hasRoom(available: free, minimum: ClipFiles.minimumFreeWhileRecording) else { return }
            self.lock.lock(); self.accepting = false; self.lock.unlock()
            DispatchQueue.main.async { self.onAutoStop?(.lowStorage) }
        }
        timer.resume()
        storageTimer = timer
    }

    private func stopStorageWatch() { storageTimer?.cancel(); storageTimer = nil }

    // MARK: Einstellungen

    static func videoSettings(size: CGSize, hevc: Bool) -> [String: Any] {
        var compression: [String: Any] = [AVVideoAverageBitRateKey: VideoGeometry.bitrate(for: size, hevc: hevc),
                                          AVVideoExpectedSourceFrameRateKey: 30,
                                          AVVideoMaxKeyFrameIntervalKey: 60]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: compression]
    }

    /// Nur Erstellungsdatum und Software. Kein `quickTimeMetadataLocationISO6709`, kein anderer Ortsschlüssel.
    static func metadata(createdAt: Date) -> [AVMetadataItem] {
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = ISO8601DateFormatter().string(from: createdAt) as NSString
        let software = AVMutableMetadataItem()
        software.identifier = .quickTimeMetadataSoftware
        software.value = "Safari Spotter iOS" as NSString
        return [date, software]
    }
}
