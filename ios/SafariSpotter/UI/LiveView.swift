import SwiftUI
import SwiftData
import AVFoundation
import QuartzCore

/// Kamerabildschirm: Vorschau, Overlay, Tracken, Game Drive, Foto, Sichtungen, Einstellungen
struct LiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = CameraController()
    @Query(sort: \Sighting.t, order: .reverse) private var sightings: [Sighting]
    @State private var showSightings = false
    @State private var showSettings = false
    @State private var showDrive = false
    @State private var correction: CorrectionTarget?
    @State private var photoAnalysis = false
    @State private var capturedPhoto: PhotoItem?

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            OverlayView(camera: camera)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { location in tap(at: location) }
            if camera.permission == .denied {
                PermissionNotice(title: "Kein Zugriff auf die Kamera",
                                 text: "Für die Live-Erkennung braucht Safari Spotter die Kamera. Sichtungen, Galerie, Bildanalyse und Game Drive funktionieren auch ohne.")
            }
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 14)
        }
        .onAppear {
            reconcileSavedDrive()
            camera.attach(context: context); camera.start(); drive.start()
            if let warning = drive.persistenceError { camera.lastError = warning }
            if settings.autoTrack { camera.setTracking(true) }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // Clips, die beim letzten Beenden der App noch aufgenommen wurden, prüfen und wieder in die Galerie holen
        .task {
            await ClipLibrary.shared.recoverInterrupted(excluding: camera.activeClipID)
            if let warning = ClipLibrary.shared.recoveryError { camera.lastError = warning }
        }
        // Meldung nach dem Speichern eines Videos nach 3 s ausblenden
        .task(id: camera.notice) {
            guard camera.notice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            camera.notice = nil
        }
        // Kamera im Hintergrund anhalten und beim Zurückkehren wieder starten (iOS unterbricht sie ohnehin)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background: drive.checkpoint(); camera.stop()
            default: break
            }
        }
        .onChange(of: drive.persistenceError) { _, warning in
            if let warning, !showDrive { camera.lastError = warning }
        }
        .onChange(of: settings.gps) { _, enabled in
            if enabled { drive.start() } else { drive.stop() }
        }
        .sheet(isPresented: $showSightings) { SightingsView(camera: camera).environmentObject(catalog).environmentObject(drive) }
        .sheet(isPresented: $showSettings) { SettingsView(camera: camera) }
        .sheet(isPresented: $showDrive) { DriveLiveView(sightings: sightings) }
        .sheet(item: $correction) { target in CorrectionSheet(target: target, camera: camera) }
        .sheet(isPresented: $photoAnalysis) { PhotoAnalysisView(camera: camera) }
        .sheet(item: $capturedPhoto) { item in PhotoAnalysisView(camera: camera, initialPhoto: item) }
        .alert("Fehler", isPresented: Binding(get: { camera.lastError != nil }, set: { _ in camera.lastError = nil })) { Button("OK") {} } message: { Text(camera.lastError ?? "") }
    }

    private func reconcileSavedDrive() {
        guard let start = drive.startedAt, drive.active else { return }
        do {
            let saved = try context.fetch(FetchDescriptor<Drive>())
            if let completed = saved.first(where: { abs($0.startedAt.timeIntervalSince(start)) < 0.001 }) {
                drive.reconcileCompletedDrive(startedAt: completed.startedAt)
            }
        } catch {
            camera.lastError = "Abgeschlossene Game Drives konnten nicht geprüft werden: \(error.localizedDescription)"
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(camera.status, systemImage: camera.tracking ? "circle.fill" : "circle").pill()
                Spacer()
                if let started = camera.recordingStartedAt { RecordingTimer(startedAt: started) }
                if camera.tracking { Text("\(Int(camera.fps)) fps").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let notice = camera.notice { Label(notice, systemImage: "video.badge.checkmark").pill() }
            if camera.lenses.count > 1 {
                Menu {
                    ForEach(camera.lenses) { lens in
                        Button { camera.selectLens(lens.id) } label: {
                            if lens.id == camera.selectedLensID { Label(lens.name, systemImage: "checkmark") }
                            else { Text(lens.name) }
                        }
                    }
                } label: {
                    Label(camera.lenses.first(where: { $0.id == camera.selectedLensID })?.name ?? "Objektiv",
                          systemImage: camera.recording ? "lock.fill" : "camera.aperture")
                }
                .pill()
                // Kein Objektivwechsel während Foto- oder Videoaufnahme
                .disabled(camera.capturingPhoto || camera.recording)
            }
            HStack {
                Button { if !drive.active { drive.startDrive() }; showDrive = true } label: {
                    Label(drive.active ? "\(fmtKm(drive.dist)) km · \(fmtDur(Date().timeIntervalSince(drive.startedAt ?? .now)))" : "Game Drive starten", systemImage: drive.active ? "stop.fill" : "play.fill")
                }.pill(active: drive.active)
                Spacer()
                Button { camera.setTracking(!camera.tracking) } label: { Label(camera.tracking ? "Tracking läuft" : "Tracken", systemImage: "scope") }.pill(active: camera.tracking)
                    .disabled(camera.permission == .denied)
            }
            if drive.active && (drive.authorization == .denied || drive.authorization == .restricted) {
                Button { openAppSettings() } label: { Label("Standort aus: Game Drive zeichnet nichts auf · Einstellungen", systemImage: "location.slash") }.pill()
            }
        }
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ZoomSlider(camera: camera)
                .pill()
            HStack {
                Button { showSightings = true } label: {
                    HStack { Text("Sichtungen"); Text("\(sightings.reduce(0) { $0 + $1.n })").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor, in: Capsule()).foregroundStyle(.black) }
                }.pill()
                Spacer()
                Button { camera.toggleRecording() } label: {
                    Image(systemName: camera.recordingFinishing || camera.recordingStarting ? "circle.dotted" : camera.recording ? "stop.circle.fill" : "record.circle").font(.title2)
                        .foregroundStyle(camera.recording ? Color.white : Color.red)
                }
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(camera.recording ? Color.red : Color.black.opacity(0.6), in: Capsule())
                .disabled(camera.permission != .granted || camera.recordingFinishing || camera.recordingStarting)
                .accessibilityLabel(camera.recordingStarting ? "Video wird vorbereitet" : camera.recordingFinishing ? "Video wird gespeichert" : camera.recording ? "Videoaufnahme stoppen" : "Videoaufnahme starten")
                Button { takePhoto() } label: {
                    Image(systemName: camera.capturingPhoto ? "circle.dotted" : "camera.circle.fill").font(.title2)
                }
                .pill()
                .disabled(camera.permission != .granted || camera.capturingPhoto)
                Button { photoAnalysis = true } label: { Image(systemName: "photo.on.rectangle") }
                    .pill().accessibilityLabel("Bilder analysieren")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .pill().accessibilityLabel("Einstellungen")
            }
        }
        .padding(.bottom, 10)
    }

    private func takePhoto() {
        camera.capturePhoto { result in
            switch result {
            case .failure(let error): camera.lastError = "Fotoaufnahme fehlgeschlagen: \(error.localizedDescription)"
            case .success(let data):
                guard let image = UIImage(data: data) else {
                    camera.lastError = "Foto konnte nicht geöffnet werden"
                    return
                }
                let thumb = image.preparingThumbnail(of: CGSize(width: 160, height: 160))?.jpegData(compressionQuality: 0.7)
                do {
                    let item = try PhotoItem(t: .now, kind: "cam", species: [], dets: [], image: data,
                                             thumb: thumb, width: Int(image.size.width * image.scale),
                                             height: Int(image.size.height * image.scale), position: nil, sightingIds: [])
                    context.insert(item)
                    try context.save()
                    capturedPhoto = item
                } catch {
                    context.rollback()
                    camera.lastError = "Foto konnte nicht gespeichert werden: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Tipp auf einen Rahmen öffnet die Korrektur (nur bei laufendem Tracking)
    private func tap(at p: CGPoint) {
        guard camera.tracking, camera.previewSize != .zero else { return }
        // Punkt aus Bildschirm- in Bildkoordinaten (die Vorschau füllt den Bildschirm mit Aspect-Fill)
        let img = ImageGeometry.imagePoint(fromView: p, viewSize: camera.previewSize, frame: camera.frameSize)
        let scale = ImageGeometry.fillScale(frame: camera.frameSize, viewSize: camera.previewSize)
        // Die Sichtung des Tracks kennt der CameraController; die Korrektur benennt sie um statt eine zweite anzulegen
        if let t = camera.track(at: img, slack: 24 / scale) { correction = CorrectionTarget(trackId: t.id, predicted: t.name.replacingOccurrences(of: "?", with: ""), thumb: nil, sightingId: nil) }
    }
}

struct CorrectionTarget: Identifiable { let id = UUID(); let trackId: Int?; let predicted: String?; let thumb: Data?; let sightingId: UUID? }

func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// Hinweis bei fehlendem Recht, mit Sprung in die Einstellungen der App
struct PermissionNotice: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(title).font(.headline)
            Text(text).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Einstellungen öffnen") { openAppSettings() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }
}

/// AVCaptureVideoPreviewLayer als SwiftUI-View
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.videoPreviewLayer.session = session; v.videoPreviewLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Rahmen und Namen über dem Kamerabild (gleiche Optik wie die Web-App)
struct OverlayView: View {
    @ObservedObject var camera: CameraController
    @EnvironmentObject private var settings: AppSettings
    static let colors: [Color] = TrackPalette.hex.map { Color(hex: $0) }   // gleiche Farben wie im eingebrannten Video
    var body: some View {
        GeometryReader { geo in
            let scale = max(geo.size.width / camera.frameSize.width, geo.size.height / camera.frameSize.height)
            let off = CGPoint(x: (camera.frameSize.width * scale - geo.size.width) / 2, y: (camera.frameSize.height * scale - geo.size.height) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(camera.tracking ? camera.tracks : []) { t in
                    let r = CGRect(x: t.box.minX * scale - off.x, y: t.box.minY * scale - off.y, width: t.box.width * scale, height: t.box.height * scale)
                    let color = Self.colors[t.colorIndex]
                    RoundedRectangle(cornerRadius: 10).strokeBorder(color, style: StrokeStyle(lineWidth: 2.2, dash: t.sure ? [] : [7, 5]))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    if settings.labels {
                        HStack(spacing: 7) { Text(t.name).font(.system(size: 14, weight: .semibold)); Text(t.sub).font(.system(size: 11, weight: .medium)).opacity(0.75) }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(t.sure ? color : Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(t.sure ? Color.black : Color.white)
                            .offset(x: r.minX, y: max(0, r.minY - 30))
                    }
                }
                if camera.tracking, settings.labels, let h = camera.hint, CACurrentMediaTime() < h.until, camera.tracks.isEmpty {
                    Text("\(h.name)  \(Int(min(h.conf, 0.99) * 100)) %").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Self.colors[0], lineWidth: 1.5))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.62)
                }
            }
            // Vorschaugrösse an die Kamera: Erkennung nur im sichtbaren Ausschnitt, Tipp-Umrechnung
            .onAppear { camera.setViewSize(geo.size) }
            .onChange(of: geo.size) { _, s in camera.setViewSize(s) }
        }
    }
}

/// Sichtbarer Timer während der Videoaufnahme ("● 01:23")
struct RecordingTimer: View {
    let startedAt: Date
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
            Label(VideoGeometry.timerText(context.date.timeIntervalSince(startedAt)), systemImage: "record.circle.fill")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.red, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityLabel("Aufnahme läuft, \(VideoGeometry.timerText(context.date.timeIntervalSince(startedAt)))")
        }
    }
}

struct ZoomSlider: View {
    @ObservedObject var camera: CameraController
    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f×", camera.zoomFactor).replacingOccurrences(of: ".", with: ",")).font(.caption2.monospacedDigit())
            Slider(value: Binding(get: { Double(camera.zoomFactor) }, set: { camera.setZoom(CGFloat($0)) }), in: 1...Double(max(camera.maxZoom, 1.01))).frame(width: 120)
        }
    }
}

extension View {
    func pill(active: Bool = false) -> some View {
        self.font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(active ? Color.accentColor : Color.black.opacity(0.6), in: Capsule())
            .foregroundStyle(active ? Color.black : Color.white)
    }
}
extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) } }
func fmtKm(_ m: Double) -> String { String(format: "%.1f", m / 1000).replacingOccurrences(of: ".", with: ",") }
func fmtDur(_ s: TimeInterval) -> String { let x = max(0, Int(s)); return "\(x / 3600):" + String(format: "%02d", (x / 60) % 60) }
func fmtClock(_ s: TimeInterval) -> String { let x = max(0, Int(s)); return "\(x / 3600):" + String(format: "%02d:%02d", (x / 60) % 60, x % 60) }
func fmtTime(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
func fmtDate(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; return f.string(from: d) }
