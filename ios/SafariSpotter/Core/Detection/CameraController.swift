import Foundation
import QuartzCore
import AVFoundation
import CoreImage
import SwiftData
import UIKit
import Combine

/// Kamera (bis 4K), Erkennungsschleife und Sichtungen. Entspricht startCamera/detectLoop/classifyPending/maybeLog der Web-App.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var tracking = false
    @Published var tracks: [TrackSnapshot] = []     // für das Overlay (Hauptthread)
    @Published var status = "Tracken aus"
    @Published var fps = 0.0
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var lastError: String?
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoom: CGFloat = 1

    struct TrackSnapshot: Identifiable { let id: Int; let box: CGRect; let name: String; let sub: String; let sure: Bool; let colorIndex: Int }

    private let queue = DispatchQueue(label: "ch.solution21.safarispotter.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var pipeline: VisionPipeline?
    private let tracker = Tracker()
    private var busy = false
    private var lastHintAt: TimeInterval = 0
    private var hintFlip = false
    private var hintRuns: [SpeciesDecision] = []
    @Published var hint: (name: String, conf: Double, until: TimeInterval)?
    private var lastHintLog: (name: String, t: TimeInterval) = ("", 0)
    private var modelContext: ModelContext?
    private let catalog = SpeciesCatalog.shared
    private let settings = AppSettings.shared
    private let drive = DriveRecorder.shared
    private var lastLoggedSpecies: (name: String, t: Date, id: UUID)?

    func attach(context: ModelContext) { modelContext = context }

    // MARK: Kamera

    func configure() {
        queue.async {
            do {
                self.pipeline = try VisionPipeline(catalog: self.catalog)
            } catch { DispatchQueue.main.async { self.lastError = "Modelle konnten nicht geladen werden: \(error.localizedDescription)" }; return }
            self.session.beginConfiguration()
            self.session.sessionPreset = self.settings.res == "2160" ? .hd4K3840x2160 : self.settings.res == "1080" ? .hd1920x1080 : .hd1280x720
            // Virtuelle Kamera (Weit + Tele) erlaubt Zoomen über alle Objektive mit einem Gerät
            let dev = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            guard let dev, let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.lastError = "Keine Kamera verfügbar" }; self.session.commitConfiguration(); return
            }
            self.session.addInput(input); self.device = dev
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.output.connection(with: .video)?.videoRotationAngle = 90   // Hochformat
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.maxZoom = min(dev.activeFormat.videoMaxZoomFactor, 15)
                self.zoomFactor = dev.videoZoomFactor
            }
        }
    }

    func setZoom(_ z: CGFloat) {
        guard let d = device else { return }
        queue.async {
            try? d.lockForConfiguration(); d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(z, d.maxAvailableVideoZoomFactor)); d.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = d.videoZoomFactor }
        }
    }

    func setTracking(_ on: Bool) {
        tracking = on
        if !on { tracker.reset(); tracks = []; hint = nil; status = "Tracken aus" } else { status = "Suche Tiere …" }
    }

    // MARK: Erkennungsschleife (ein Frame nach dem anderen, nie überlappend)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard tracking, !busy, let pipeline, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        let t0 = CACurrentMediaTime()
        let image = CIImage(cvPixelBuffer: pb)
        let size = image.extent.size
        let visible = CGRect(origin: .zero, size: size)
        let region = drive.currentRegion(setting: settings.region)
        do {
            let n = settings.far == "max" ? 3 : settings.far == "off" ? 0 : 2
            let dets = try pipeline.detectAll(in: image, visible: visible, threshold: settings.threshold, tiles: n)
            let now = CACurrentMediaTime()
            tracker.update(with: dets, visible: visible, now: now)
            if pipeline.usesYolo {
                // Eigener Detektor: Art kommt mit jedem Rahmen, Sichtung sofort möglich
                for t in tracker.applyDetectorSpecies(catalog: catalog, probs: { pipeline.probs(fromDetector: $0, region: region) }) where t.decision.sure { maybeLog(t, image: image, size: size) }
            }
            if let cand = tracker.candidateForClassification(now: now), cand.box.width >= 12, cand.box.height >= 12 {
                let sq = VisionPipeline.cropSquare(cand.box, in: size)
                let probs = try pipeline.classify(image, square: sq, region: region)
                let d = tracker.apply(probs: probs, to: cand, catalog: catalog, now: now)
                if d.sure { maybeLog(cand, image: image, size: size) }
                collectForReview(cand, decision: d, image: image, square: sq, region: region)
            }
            try idleHint(image: image, size: size, region: region, now: now)
        } catch { DispatchQueue.main.async { self.lastError = error.localizedDescription } }
        let dt = CACurrentMediaTime() - t0
        let snap = tracker.tracks.filter { $0.isShown }.map { t in
            TrackSnapshot(id: t.id, box: t.box, name: t.displayName,
                          sub: t.decision.other ? "kein Safari-Tier" : t.locked ? "bestätigt" : t.decision.name != nil ? "\(Int(min(t.decision.confidence, 0.99) * 100)) %" : "unbestimmt",
                          sure: t.decision.sure, colorIndex: t.colorIndex)
        }
        DispatchQueue.main.async {
            self.frameSize = size; self.tracks = snap; self.fps = self.fps * 0.8 + (1 / max(dt, 0.001)) * 0.2
            let n = snap.count
            if n == 0, let h = self.hint, CACurrentMediaTime() < h.until { self.status = "\(h.name) vermutet" }
            else { self.status = n == 0 ? "Suche Tiere …" : n == 1 ? "1 Tier im Bild" : "\(n) Tiere im Bild" }
            self.busy = false
        }
    }

    /// Hinweis ohne Rahmen: Bildmitte prüfen, wenn der Detektor nichts findet (Krokodil, Schildkröte, Waran)
    private func idleHint(image: CIImage, size: CGSize, region: Region?, now: TimeInterval) throws {
        guard let pipeline else { return }
        if tracker.tracks.contains(where: { $0.isShown && $0.missed == 0 }) { hintRuns = []; return }
        if now - lastHintAt < 0.7 { return }
        lastHintAt = now; hintFlip.toggle()
        let side = min(size.width, size.height) * (hintFlip ? 0.7 : 0.4)
        let sq = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        let d = SpeciesDecision.decide(try pipeline.classify(image, square: sq, region: region), catalog: catalog)
        hintRuns.append(d); if hintRuns.count > 4 { hintRuns.removeFirst() }
        let same = d.name == nil ? 0 : hintRuns.filter { $0.name == d.name && !$0.other && $0.confidence >= 0.6 }.count
        if same >= 2, !d.other, let name = d.name {
            DispatchQueue.main.async { self.hint = (name, d.confidence, now + 1.8) }
            if same >= 4, d.confidence >= 0.7, !(lastHintLog.name == name && now - lastHintLog.t < 60) {
                lastHintLog = (name, now)
                let thumb = pipeline.jpeg(image, rect: sq, size: 96, quality: 0.6)
                log(name: name, key: d.key, thumb: thumb, src: "hint", image: image, size: size)
            }
        }
    }

    // MARK: Sichtungen

    private func maybeLog(_ t: Track, image: CIImage, size: CGSize) {
        guard !t.logged, let name = t.decision.name, t.decision.sure, !t.decision.other, t.hits >= 4, CACurrentMediaTime() - t.born >= 1.2, let pipeline else { return }
        t.logged = true
        let thumb = pipeline.jpeg(image, rect: VisionPipeline.cropSquare(t.box, in: size, pad: 0.08), size: 96, quality: 0.6)
        t.sightingId = log(name: name, key: t.decision.key, thumb: thumb, src: "cam", image: image, size: size)
    }

    /// Loggt eine Sichtung (fasst gleiche Art innert 30 s zusammen) und speichert bei neuen Einträgen einen Schnappschuss
    @discardableResult
    func log(name: String, key: String?, thumb: Data?, src: String, image: CIImage?, size: CGSize, count: Int = 1, noMerge: Bool = false) -> UUID? {
        if Thread.isMainThread { return logOnMain(name: name, key: key, thumb: thumb, src: src, image: image, size: size, count: count, noMerge: noMerge) }
        var result: UUID?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { result = self.logOnMain(name: name, key: key, thumb: thumb, src: src, image: image, size: size, count: count, noMerge: noMerge); sem.signal() }
        sem.wait()
        return result
    }

    @discardableResult
    private func logOnMain(name: String, key: String?, thumb: Data?, src: String, image: CIImage?, size: CGSize, count: Int, noMerge: Bool) -> UUID? {
        var result: UUID?
        do {
            guard let ctx = self.modelContext else { return nil }
            if !noMerge, let last = self.lastLoggedSpecies, last.name == name, Date().timeIntervalSince(last.t) < 30,
               let existing = try? ctx.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.id == last.id })).first {
                existing.n += count; existing.t = .now; if existing.thumb == nil { existing.thumb = thumb }
                self.lastLoggedSpecies = (name, .now, existing.id); return existing.id
            }
            let sensitive = self.catalog.isSensitive(name: name)
            let pos = self.drive.lastFix.flatMap { Date().timeIntervalSince($0.timestamp) < 180 ? Position.from($0, sensitive: sensitive) : nil }
            let s = Sighting(name: name, key: key, n: count, position: pos, thumb: thumb, src: src)
            ctx.insert(s); try? ctx.save()
            self.lastLoggedSpecies = (name, .now, s.id); result = s.id
            if self.settings.snapshots, let image, let pipeline = self.pipeline { self.snapshot(image: image, size: size, names: [name], sightingIds: [s.id], pipeline: pipeline, ctx: ctx) }
        }
        return result
    }

    /// Schnappschuss des Kamerabilds (max. 1280 px) mit den Rahmen, wie snapshotFrame() im Web
    private func snapshot(image: CIImage, size: CGSize, names: [String], sightingIds: [UUID], pipeline: VisionPipeline, ctx: ModelContext) {
        let k = min(1, 1280 / max(size.width, size.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let ciCtx = CIContext()
        guard let jpeg = ciCtx.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]) else { return }
        let dets = tracker.tracks.filter { $0.isShown }.map { t in PhotoDet(x: t.box.minX * k, y: t.box.minY * k, w: t.box.width * k, h: t.box.height * k, name: t.decision.name, conf: t.decision.confidence, sure: t.decision.sure) }
        let sensitive = names.contains { catalog.isSensitive(name: $0) }
        let pos = drive.lastFix.map { Position.from($0, sensitive: sensitive) }
        let thumb = pipeline.jpeg(scaled, rect: CGRect(x: (scaled.extent.width - min(scaled.extent.width, scaled.extent.height)) / 2, y: (scaled.extent.height - min(scaled.extent.width, scaled.extent.height)) / 2, width: min(scaled.extent.width, scaled.extent.height), height: min(scaled.extent.width, scaled.extent.height)), size: 160, quality: 0.7)
        ctx.insert(PhotoItem(t: .now, kind: "auto", species: names, dets: dets, image: jpeg, thumb: thumb, width: Int(scaled.extent.width), height: Int(scaled.extent.height), position: pos, sightingIds: sightingIds))
        try? ctx.save()
    }

    /// Unsichere, stabile Treffer in die Prüfliste (30 bis 70 %)
    private func collectForReview(_ t: Track, decision d: SpeciesDecision, image: CIImage, square: CGRect, region: Region?) {
        guard settings.collect, !t.collected, t.hits >= 4, let name = d.name, !d.other, d.confidence >= 0.3, d.confidence < 0.7, let pipeline, let jpeg = pipeline.jpeg(image, rect: square) else { return }
        t.collected = true
        DispatchQueue.main.async {
            guard let ctx = self.modelContext else { return }
            ctx.insert(Correction(image: jpeg, predicted: name, predKey: d.key, conf: d.confidence, status: "review", region: region?.key)); try? ctx.save()
        }
    }

    /// Korrektur per Tipp auf einen Rahmen: Track sperren und Sichtung umbenennen
    func correct(trackId: Int, name: String?, key: String, isNone: Bool, isOther: Bool) {
        queue.async {
            guard let t = self.tracker.tracks.first(where: { $0.id == trackId }) else { return }
            t.locked = true
            if isNone { self.tracker.tracks.removeAll { $0.id == trackId } }
            else if let name { t.decision = SpeciesDecision(name: name, key: key, confidence: 1, sure: !isOther, other: isOther) }
        }
    }

    func track(at point: CGPoint, slack: CGFloat) -> TrackSnapshot? {
        tracks.map { t -> (TrackSnapshot, CGFloat) in
            let dx = max(0, t.box.minX - point.x, point.x - t.box.maxX), dy = max(0, t.box.minY - point.y, point.y - t.box.maxY)
            return (t, dx + dy)
        }.filter { $0.1 <= slack }.min { $0.1 < $1.1 }?.0
    }
}
