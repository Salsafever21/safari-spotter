import Foundation
import QuartzCore
import AVFoundation
import CoreImage
import SwiftData
import UIKit
import Combine

private final class PhotoCaptureHandler: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private let lock = NSLock()
    private var completed = false
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { finish(.failure(error)) }
        else if let data = photo.fileDataRepresentation() { finish(.success(data)) }
        else { finish(.failure(NSError(domain: "SafariSpotter.Photo", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "Foto konnte nicht gelesen werden"]))) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { finish(.failure(error)) }
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(result)
    }
}

/// Kamera (bis 4K), Erkennungsschleife und Sichtungen. Entspricht startCamera/detectLoop/classifyPending/maybeLog der Web-App.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Permission { case unknown, granted, denied }
    struct Lens: Identifiable, Equatable { let id: String; let name: String }

    let session = AVCaptureSession()
    @Published var tracking = false
    @Published var tracks: [TrackSnapshot] = []     // für das Overlay (Hauptthread)
    @Published var status = "Tracken aus"
    @Published var fps = 0.0
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var lastError: String?
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoom: CGFloat = 1
    @Published var permission: Permission = .unknown
    @Published var lenses: [Lens] = []
    @Published var selectedLensID = ""
    @Published var capturingPhoto = false
    @Published private(set) var previewSize: CGSize = .zero   // Grösse der Vorschau auf dem Bildschirm (Hauptthread)
    @Published private(set) var recording = false            // Videoaufnahme läuft (Hauptthread)
    @Published private(set) var recordingFinishing = false   // Videodatei wird noch fertig geschrieben
    @Published private(set) var recordingStartedAt: Date?
    @Published var notice: String?                            // kurze Meldung, z. B. "Video gespeichert"
    private(set) var activeClipID: UUID?                      // laufender Clip, von der Wiederherstellung ausgenommen

    struct TrackSnapshot: Identifiable { let id: Int; let box: CGRect; let name: String; let sub: String; let sure: Bool; let colorIndex: Int }

    /// Erkennung, Session-Konfiguration, Tracker (bisheriger Kamera-Thread)
    private let queue = DispatchQueue(label: "ch.solution21.safarispotter.camera", qos: .userInitiated)
    /// Bildlieferung der Kamera: gibt jedes Bild sofort an die Aufnahme und nur bei freier Erkennung an `queue` weiter
    private let frameQueue = DispatchQueue(label: "ch.solution21.safarispotter.frames", qos: .userInitiated)
    private let detectionGate = DetectionGate()
    let recorder = VideoRecorder()
    private let output = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoHandler: PhotoCaptureHandler?
    private var device: AVCaptureDevice?
    private var availableDevices: [AVCaptureDevice] = []
    private var pipeline: VisionPipeline?
    private let tracker = Tracker()
    private var processingTracking = false   // nur auf `queue`
    private var processingGeneration = 0     // nur auf `queue`
    private var displayGeneration = 0        // nur auf dem Hauptthread
    private var configured = false          // nur auf `queue`
    private var viewSize: CGSize = .zero    // nur auf `queue`: Vorschaugrösse für den sichtbaren Ausschnitt
    private var observers: [NSObjectProtocol] = []
    private var lastHintAt: TimeInterval = 0
    private var hintFlip = false
    private var hintRuns: [SpeciesDecision] = []
    @Published var hint: (name: String, conf: Double, until: TimeInterval)?
    private var lastHintLog: (name: String, t: TimeInterval) = ("", 0)
    private var modelContext: ModelContext?
    private let catalog = SpeciesCatalog.shared
    private let settings = AppSettings.shared
    private let drive = DriveRecorder.shared
    private var lastLoggedSpecies: (name: String, t: Date, id: UUID)?   // nur Hauptthread

    override init() {
        super.init()
        observeSession()
        recorder.isSensitive = { [catalog = self.catalog] in catalog.isSensitive(name: $0) }
        recorder.onAutoStop = { [weak self] reason in self?.stopRecording(reason: reason) }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func attach(context: ModelContext) { modelContext = context }

    // MARK: Lebenszyklus und Rechte

    /// Kamera starten (beim Erscheinen und bei Rückkehr in den Vordergrund): Recht prüfen bzw. anfragen, einmal konfigurieren,
    /// Session starten. Mehrfache Aufrufe sind unschädlich. Aufruf vom Hauptthread.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
            queue.async {
                self.configureIfNeeded()
                if self.configured && !self.session.isRunning { self.session.startRunning() }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.start() } else { self.permission = .denied } }
            }
        default:
            permission = .denied
        }
    }

    /// Kamera anhalten (App im Hintergrund). Die Absicht "Tracken" bleibt erhalten, laufende Tracks werden verworfen.
    /// Eine laufende Videoaufnahme wird zuerst sauber abgeschlossen (mit Hintergrundzeit für das Fertigschreiben).
    func stop() {
        if recording { stopRecording(reason: .background) }
        displayGeneration += 1
        let generation = displayGeneration
        tracks = []; hint = nil
        status = tracking ? "Suche Tiere …" : "Tracken aus"
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.tracker.reset(); self.hintRuns = []
            self.processingGeneration = generation
        }
    }

    /// Vorschaugrösse vom Bildschirm (Hauptthread); bestimmt den sichtbaren Ausschnitt für die Erkennung
    func setViewSize(_ s: CGSize) {
        guard s != previewSize, s.width > 0, s.height > 0 else { return }
        previewSize = s
        queue.async { self.viewSize = s }
    }

    /// Unterbrechungen (Anruf, andere App nutzt die Kamera) und Laufzeitfehler der Session
    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] n in
            guard let self else { return }
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.lastError = "Kamera-Fehler: \(err?.localizedDescription ?? "unbekannt")"
            self.stopRecording(reason: .failed(err?.localizedDescription ?? "Kamera-Fehler"))
            // z. B. nach einem Neustart der Mediendienste: Session neu starten, solange die App aktiv ist
            if UIApplication.shared.applicationState == .active {
                self.queue.async { if self.configured && !self.session.isRunning { self.session.startRunning() } }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.status = "Kamera unterbrochen"
            // Anruf, Multitasking, andere App mit Kamera: bisherige Aufnahme sauber abschliessen
            self?.stopRecording(reason: .interrupted)
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recording, ProcessInfo.processInfo.thermalState == .critical else { return }
            self.stopRecording(reason: .thermal)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.status = self.tracking ? "Suche Tiere …" : "Tracken aus"
        })
    }

    // MARK: Kamera

    /// Modelle laden und Session einrichten, genau einmal (auf `queue`). Ohne Modelle bleibt wenigstens das Kamerabild.
    private func configureIfNeeded() {
        guard !configured else { return }
        if pipeline == nil {
            do { pipeline = try VisionPipeline(catalog: catalog) }
            catch { let msg = error.localizedDescription; DispatchQueue.main.async { self.lastError = "Modelle konnten nicht geladen werden: \(msg)" } }
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                          .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        availableDevices = discovery.devices
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.inputs.isEmpty {
            // Ein echtes Weitwinkel startet mit dem gewohnten 1× Bildausschnitt.
            let dev = availableDevices.first(where: { $0.uniqueID == settings.lensID })
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            guard let dev, let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
                DispatchQueue.main.async { self.lastError = "Keine Kamera verfügbar" }; return
            }
            session.addInput(input); device = dev
        }
        let preset: AVCaptureSession.Preset = settings.res == "2160" ? .hd4K3840x2160 : settings.res == "1080" ? .hd1920x1080 : .hd1280x720
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // Die Bildlieferung kehrt sofort zurück (Aufnahme auf eigener Queue, Erkennung nur bei freiem Tor), darum keine
            // verspäteten Bilder verwerfen: sonst gingen bei einer Aufnahme Bilder verloren
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { DispatchQueue.main.async { self.lastError = "Kamerabild nicht verfügbar" }; return }
            session.addOutput(output)
        }
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                DispatchQueue.main.async { self.lastError = "Fotoaufnahme nicht verfügbar" }; return
            }
            session.addOutput(photoOutput)
        }
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }   // Hochformat
        if let c = photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        configured = true
        if let dev = device, !availableDevices.contains(where: { $0.uniqueID == dev.uniqueID }) { availableDevices.insert(dev, at: 0) }
        if let dev = device {
            let options = availableDevices.map { Lens(id: $0.uniqueID, name: Self.lensName($0)) }
            DispatchQueue.main.async {
                self.maxZoom = min(dev.activeFormat.videoMaxZoomFactor, 15)
                self.zoomFactor = dev.videoZoomFactor
                self.lenses = options
                self.selectedLensID = dev.uniqueID
            }
        }
    }

    func setZoom(_ z: CGFloat) {
        queue.async { [self] in
            guard let d = self.device else { return }
            try? d.lockForConfiguration(); d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(z, d.maxAvailableVideoZoomFactor)); d.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = d.videoZoomFactor }
        }
    }

    private static func lensName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera: return "Automatisch"
        case .builtInUltraWideCamera: return "Ultraweit"
        case .builtInTelephotoCamera: return "Tele"
        default: return "Weitwinkel"
        }
    }

    func selectLens(_ id: String) {
        // Während einer Videoaufnahme kein Objektivwechsel (Bildgrösse und Bildausschnitt des Clips bleiben fest)
        guard id != selectedLensID, !recording else { return }
        displayGeneration += 1
        let generation = displayGeneration
        tracks = []; hint = nil
        status = tracking ? "Suche Tiere …" : "Tracken aus"
        queue.async {
            self.processingGeneration = generation
            self.tracker.reset()
            guard self.configured, let next = self.availableDevices.first(where: { $0.uniqueID == id }),
                  next.uniqueID != self.device?.uniqueID,
                  let newInput = try? AVCaptureDeviceInput(device: next),
                  let oldInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) else { return }
            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.device = next
            } else {
                self.session.addInput(oldInput)
                DispatchQueue.main.async { self.lastError = "Objektiv konnte nicht gewechselt werden" }
            }
            if let c = self.output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if let c = self.photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            self.session.commitConfiguration()
            let active = self.device
            DispatchQueue.main.async {
                self.tracks = []
                self.selectedLensID = active?.uniqueID ?? ""
                self.settings.lensID = active?.uniqueID ?? ""
                self.maxZoom = min(active?.activeFormat.videoMaxZoomFactor ?? 1, 15)
                self.zoomFactor = active?.videoZoomFactor ?? 1
            }
        }
    }

    /// A full-resolution still is delivered to the caller; the caller persists it before analysis.
    func capturePhoto(_ completion: @escaping (Result<Data, Error>) -> Void) {
        guard !capturingPhoto, permission == .granted else { return }
        capturingPhoto = true
        queue.async { [self] in
            guard self.configured, self.session.isRunning else {
                DispatchQueue.main.async {
                    self.capturingPhoto = false
                    self.lastError = "Kamera ist noch nicht bereit"
                }
                return
            }
            guard self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) else {
                DispatchQueue.main.async {
                    self.capturingPhoto = false
                    self.lastError = "JPEG-Fotoaufnahme ist auf diesem Gerät nicht verfügbar"
                }
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            let handler = PhotoCaptureHandler { [weak self] result in
                guard let self else { return }
                self.queue.async { self.photoHandler = nil }
                DispatchQueue.main.async {
                    self.capturingPhoto = false
                    completion(result)
                }
            }
            self.photoHandler = handler
            self.photoOutput.capturePhoto(with: settings, delegate: handler)
        }
    }

    // MARK: Videoaufnahme (Hauptthread)

    func toggleRecording() {
        if recording { stopRecording(reason: .user) } else { startRecording() }
    }

    /// Startet eine Aufnahme, mit oder ohne laufende Erkennung. Prüft Recht und freien Speicher; der Clip bekommt höchstens
    /// die vergröberte 10-km-Position (die Videodatei selbst gar keinen Ort).
    func startRecording() {
        guard !recording, !recordingFinishing else { return }
        guard permission == .granted else { lastError = "Für Videos braucht Safari Spotter die Kamera."; return }
        let directory: URL
        do { directory = try ClipFiles.defaultDirectory() }
        catch { lastError = "Videoordner nicht verfügbar: \(error.localizedDescription)"; return }
        guard ClipFiles.hasRoom(available: ClipFiles.availableCapacity(at: directory), minimum: ClipFiles.minimumFreeToStart) else {
            lastError = "Zu wenig freier Speicher für ein Video (mindestens 1 GB)."; return
        }
        let position = drive.lastFix.flatMap { fix in
            Date().timeIntervalSince(fix.timestamp) < 180 ? Position.coarsen(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude) : nil
        }
        let now = Date()
        let info = VideoRecorder.StartInfo(createdAt: now, directory: directory, burnIn: settings.burnIn, labels: settings.labels,
                                           position: position, lens: lenses.first { $0.id == selectedLensID }?.name,
                                           trackingActive: tracking,
                                           stamp: settings.burnIn ? "Safari Spotter · \(fmtDate(now)) \(fmtTime(now))" : nil)
        activeClipID = info.id
        recorder.start(info)
        recording = true
        recordingStartedAt = now
        setLensSwitchingLocked(true)
    }

    /// Beendet die Aufnahme und schreibt den Clip fertig, auch wenn die App gerade in den Hintergrund geht
    func stopRecording(reason: VideoRecorder.StopReason) {
        guard recording else { return }
        recording = false
        recordingFinishing = true
        recordingStartedAt = nil
        let task = BackgroundTask.begin("Safari Spotter Video")
        recorder.stop(reason: reason) { [weak self] result in
            defer { task.end() }
            guard let self else { return }
            defer { self.recordingFinishing = false }
            self.activeClipID = nil
            ClipLibrary.shared.reload()
            switch result {
            case .success(let clip?):
                let base = clip.state == .complete ? "Video gespeichert · \(VideoGeometry.timerText(clip.duration))" : "Video unvollständig gespeichert"
                self.notice = Self.stopNotice(base, reason: reason)
            case .success(nil):
                self.notice = "Keine Videobilder aufgenommen"
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
        setLensSwitchingLocked(false)
    }

    static func stopNotice(_ base: String, reason: VideoRecorder.StopReason) -> String {
        switch reason {
        case .user, .background: return base
        case .interrupted: return base + " (Kamera unterbrochen)"
        case .thermal: return base + " (iPhone zu heiss)"
        case .lowStorage: return base + " (Speicher fast voll)"
        case .failed(let message): return base + " (\(message))"
        }
    }

    /// Beim virtuellen Mehrfachobjektiv ("Automatisch") schaltet iOS selbst zwischen den Objektiven um; während einer
    /// Aufnahme wird das gesperrt, der Zoom bleibt dann digital auf dem aktuellen Objektiv
    private func setLensSwitchingLocked(_ locked: Bool) {
        queue.async {
            guard let d = self.device, d.isVirtualDevice, d.primaryConstituentDeviceSwitchingBehavior != .unsupported else { return }
            do {
                try d.lockForConfiguration()
                d.setPrimaryConstituentDeviceSwitchingBehavior(locked ? .locked : .auto, restrictedSwitchingBehaviorConditions: [])
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func setTracking(_ on: Bool) {
        displayGeneration += 1
        let generation = displayGeneration
        tracking = on
        tracks = []; hint = nil; fps = 0
        status = on ? "Suche Tiere …" : "Tracken aus"
        detectionGate.setWanted(on)
        if !on { recorder.clearOverlay() }
        queue.async {
            self.processingTracking = on
            self.processingGeneration = generation
            self.tracker.reset(); self.hintRuns = []
        }
    }

    // MARK: Bildlieferung (frameQueue): Aufnahme und Erkennung getrennt

    /// Jedes Kamerabild geht sofort an die Videoaufnahme (eigene Queue). Die Erkennung bekommt ein Bild nur, wenn sie
    /// eingeschaltet und frei ist; Bilder werden für sie nie angestaut. So bremst eine langsame Erkennung die Aufnahme nie.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        detectionGate.route(record: { recorder.append(sampleBuffer) }, detectOn: queue) { self.detect(sampleBuffer) }
    }

    /// Die Kamera hat ein Bild verworfen (z. B. Puffer voll); zählt bei laufender Aufnahme als `droppedFrames`
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recorder.noteDroppedFrame()
    }

    // MARK: Erkennungsschleife (queue, ein Bild nach dem anderen, nie überlappend)

    private func detect(_ sampleBuffer: CMSampleBuffer) {
        guard processingTracking, let pipeline, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let generation = processingGeneration
        let t0 = CACurrentMediaTime()
        let image = CIImage(cvPixelBuffer: pb)
        let size = image.extent.size
        // Nur der Teil, den die Vorschau (Aspect-Fill) auf dem Bildschirm zeigt, wie visibleRegion() im Web
        let visible = ImageGeometry.visibleRegion(frame: size, viewSize: viewSize)
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
                collectForReview(cand, decision: d, image: image, square: sq, region: region, generation: generation)
            }
            try idleHint(image: image, size: size, region: region, now: now, generation: generation)
        } catch { DispatchQueue.main.async { self.lastError = error.localizedDescription } }
        let dt = CACurrentMediaTime() - t0
        let snap = tracker.tracks.filter { $0.isShown }.map { t in
            TrackSnapshot(id: t.id, box: t.box, name: t.displayName,
                          sub: t.decision.other ? "kein Safari-Tier" : t.locked ? "bestätigt" : t.decision.name != nil ? "\(Int(min(t.decision.confidence, 0.99) * 100)) %" : "unbestimmt",
                          sure: t.decision.sure, colorIndex: t.colorIndex)
        }
        // Rahmen für das eingebrannte Video (nur aus dem aktuellen Tracking-Durchlauf)
        if generation == processingGeneration && processingTracking { recorder.updateOverlay(snap, frameSize: size) }
        DispatchQueue.main.async { self.publishFrame(snap, size: size, elapsed: dt, generation: generation) }
    }

    /// Ergebnisse eines bereits beendeten Tracking-Durchlaufs dürfen die ausgeschaltete Anzeige nicht neu befüllen.
    func publishFrame(_ snapshots: [TrackSnapshot], size: CGSize, elapsed: TimeInterval, generation: Int) {
        guard tracking, generation == displayGeneration else { return }
        frameSize = size; tracks = snapshots; fps = fps * 0.8 + (1 / max(elapsed, 0.001)) * 0.2
        let n = snapshots.count
        if n == 0, let hint, CACurrentMediaTime() < hint.until { status = "\(hint.name) vermutet" }
        else { status = n == 0 ? "Suche Tiere …" : n == 1 ? "1 Tier im Bild" : "\(n) Tiere im Bild" }
    }

    var currentDisplayGeneration: Int { displayGeneration }

    /// Hinweis ohne Rahmen: Bildmitte prüfen, wenn der Detektor nichts findet (Krokodil, Schildkröte, Waran)
    private func idleHint(image: CIImage, size: CGSize, region: Region?, now: TimeInterval, generation: Int) throws {
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
            DispatchQueue.main.async {
                if self.tracking && generation == self.displayGeneration { self.hint = (name, d.confidence, now + 1.8) }
            }
            if same >= 4, d.confidence >= 0.7, !(lastHintLog.name == name && now - lastHintLog.t < 60) {
                lastHintLog = (name, now)
                let thumb = pipeline.jpeg(image, rect: sq, size: 96, quality: 0.6)
                log(name: name, key: d.key, thumb: thumb, src: "hint", image: image, size: size, generation: generation)
            }
        }
    }

    // MARK: Sichtungen

    private func maybeLog(_ t: Track, image: CIImage, size: CGSize) {
        guard !t.logged, let name = t.decision.name, t.decision.sure, !t.decision.other, t.hits >= 4, CACurrentMediaTime() - t.born >= 1.2, let pipeline else { return }
        t.logged = true
        let thumb = pipeline.jpeg(image, rect: VisionPipeline.cropSquare(t.box, in: size, pad: 0.08), size: 96, quality: 0.6)
        t.sightingId = log(name: name, key: t.decision.key, thumb: thumb, src: "cam", image: image, size: size, generation: processingGeneration)
    }

    /// Loggt eine Sichtung (fasst gleiche Art innert 30 s zusammen) und speichert bei neuen Einträgen einen Schnappschuss
    @discardableResult
    func log(name: String, key: String?, thumb: Data?, src: String, image: CIImage?, size: CGSize, count: Int = 1, noMerge: Bool = false, generation: Int? = nil) -> UUID? {
        if Thread.isMainThread { return logOnMain(name: name, key: key, thumb: thumb, src: src, image: image, size: size, count: count, noMerge: noMerge, generation: generation) }
        var result: UUID?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { result = self.logOnMain(name: name, key: key, thumb: thumb, src: src, image: image, size: size, count: count, noMerge: noMerge, generation: generation); sem.signal() }
        sem.wait()
        return result
    }

    @discardableResult
    private func logOnMain(name: String, key: String?, thumb: Data?, src: String, image: CIImage?, size: CGSize, count: Int, noMerge: Bool, generation: Int? = nil) -> UUID? {
        if let generation, (!tracking || generation != displayGeneration) { return nil }
        guard let ctx = self.modelContext else { return nil }
        if !noMerge, let last = self.lastLoggedSpecies, last.name == name, Date().timeIntervalSince(last.t) < 30,
           let existing = SightingStore(context: ctx, catalog: catalog).sighting(id: last.id) {
            existing.n += count; existing.t = .now; if existing.thumb == nil { existing.thumb = thumb }
            try? ctx.save()
            recorder.noteSighting(id: existing.id, name: name)
            self.lastLoggedSpecies = (name, .now, existing.id); return existing.id
        }
        let sensitive = self.catalog.isSensitive(name: name)
        let pos = self.drive.lastFix.flatMap { Date().timeIntervalSince($0.timestamp) < 180 ? Position.from($0, sensitive: sensitive) : nil }
        let s = Sighting(name: name, key: key, n: count, position: pos, thumb: thumb, src: src)
        ctx.insert(s); try? ctx.save()
        recorder.noteSighting(id: s.id, name: name)   // verknüpft die Sichtung mit einem laufenden Clip
        self.lastLoggedSpecies = (name, .now, s.id)
        if self.settings.snapshots, let image, let pipeline = self.pipeline { self.snapshot(image: image, size: size, names: [name], sightingIds: [s.id], pipeline: pipeline, ctx: ctx) }
        return s.id
    }

    /// Schnappschuss des Kamerabilds (max. 1280 px) mit den Rahmen, wie snapshotFrame() im Web
    private func snapshot(image: CIImage, size: CGSize, names: [String], sightingIds: [UUID], pipeline: VisionPipeline, ctx: ModelContext) {
        let k = min(1, 1280 / max(size.width, size.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let ciCtx = CIContext()
        guard let jpeg = ciCtx.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]) else { return }
        let dets = tracker.tracks.filter { $0.isShown }.map { t in PhotoDet(x: t.box.minX * k, y: t.box.minY * k, w: t.box.width * k, h: t.box.height * k, name: t.decision.name, conf: t.decision.confidence, sure: t.decision.sure) }
        // Artenschutz: das Foto wird ungenau, sobald irgendein Tier im Bild sensibel ist, nicht nur das gerade geloggte
        let sensitive = LocationProtection.containsSensitive(names.map { $0 as String? } + dets.map { $0.name }, isSensitive: { self.catalog.isSensitive(name: $0) })
        let pos = drive.lastFix.map { Position.from($0, sensitive: sensitive) }
        let side = min(scaled.extent.width, scaled.extent.height)
        let thumb = pipeline.jpeg(scaled, rect: CGRect(x: (scaled.extent.width - side) / 2, y: (scaled.extent.height - side) / 2, width: side, height: side), size: 160, quality: 0.7)
        ctx.insert(PhotoItem(t: .now, kind: "auto", species: names, dets: dets, image: jpeg, thumb: thumb, width: Int(scaled.extent.width), height: Int(scaled.extent.height), position: pos, sightingIds: sightingIds))
        try? ctx.save()
    }

    /// Unsichere, stabile Treffer in die Prüfliste (30 bis 70 %)
    private func collectForReview(_ t: Track, decision d: SpeciesDecision, image: CIImage, square: CGRect, region: Region?, generation: Int) {
        guard settings.collect, !t.collected, t.hits >= 4, let name = d.name, !d.other, d.confidence >= 0.3, d.confidence < 0.7, let pipeline, let jpeg = pipeline.jpeg(image, rect: square) else { return }
        t.collected = true
        DispatchQueue.main.async {
            guard self.tracking, generation == self.displayGeneration else { return }
            guard let ctx = self.modelContext else { return }
            ctx.insert(Correction(image: jpeg, predicted: name, predKey: d.key, conf: d.confidence, status: "review", region: region?.key)); try? ctx.save()
        }
    }

    // MARK: Korrektur

    /// Korrektur per Tipp auf einen Rahmen: Track sperren und die bereits geloggte Sichtung umbenennen, abspalten oder entfernen.
    /// Nur wenn der Track noch keine Sichtung hat, entsteht eine neue (wie app.js; nie zwei Sichtungen für dasselbe Tier).
    func correct(trackId: Int, name: String, key: String, isNone: Bool, isOther: Bool) {
        queue.async {
            guard let t = self.tracker.track(id: trackId) else { return }
            t.locked = true; t.logged = true
            let existing = t.sightingId
            if isNone { self.tracker.remove(id: trackId) }
            else { t.decision = SpeciesDecision(name: name, key: key, confidence: 1, sure: !isOther, other: isOther) }
            DispatchQueue.main.async {
                guard let ctx = self.modelContext else { return }
                let id = SightingStore(context: ctx, catalog: self.catalog).applyTrackCorrection(existingId: existing, name: name, key: key, isNone: isNone, isOther: isOther) {
                    self.logOnMain(name: name, key: key, thumb: nil, src: "cam", image: nil, size: .zero, count: 1, noMerge: true)
                }
                if let existing { self.noteSightingChanged(existing) }
                self.queue.async { t.sightingId = id }
            }
        }
    }

    /// Nach Umbenennen oder Entfernen einer Sichtung (Hauptthread): Die 30-s-Zusammenfassung darf nicht in eine umbenannte
    /// oder gelöschte Sichtung weiterzählen.
    func noteSightingChanged(_ id: UUID) {
        guard let last = lastLoggedSpecies, last.id == id, let ctx = modelContext else { return }
        if let s = SightingStore(context: ctx, catalog: catalog).sighting(id: id) { lastLoggedSpecies = (s.name, last.t, id) }
        else { lastLoggedSpecies = nil }
    }

    func track(at point: CGPoint, slack: CGFloat) -> TrackSnapshot? {
        tracks.map { t -> (TrackSnapshot, CGFloat) in
            let dx = max(0, t.box.minX - point.x, point.x - t.box.maxX), dy = max(0, t.box.minY - point.y, point.y - t.box.maxY)
            return (t, dx + dy)
        }.filter { $0.1 <= slack }.min { $0.1 < $1.1 }?.0
    }
}
