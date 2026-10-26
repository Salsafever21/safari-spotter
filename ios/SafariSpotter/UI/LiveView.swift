import SwiftUI
import SwiftData
import AVFoundation
import QuartzCore

/// Kamerabildschirm: Vorschau, Overlay, Tracken, Game Drive, Foto, Sichtungen, Einstellungen
struct LiveView: View {
    @Environment(\.modelContext) private var context
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

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            OverlayView(camera: camera)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { location in tap(at: location) }
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 14)
        }
        .onAppear {
            camera.attach(context: context); camera.configure(); drive.start()
            if settings.autoTrack { camera.setTracking(true) }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .sheet(isPresented: $showSightings) { SightingsView(camera: camera).environmentObject(catalog).environmentObject(drive) }
        .sheet(isPresented: $showSettings) { SettingsView(camera: camera) }
        .sheet(isPresented: $showDrive) { DriveLiveView(sightings: sightings) }
        .sheet(item: $correction) { target in CorrectionSheet(target: target, camera: camera) }
        .sheet(isPresented: $photoAnalysis) { PhotoAnalysisView(camera: camera) }
        .alert("Fehler", isPresented: Binding(get: { camera.lastError != nil }, set: { _ in camera.lastError = nil })) { Button("OK") {} } message: { Text(camera.lastError ?? "") }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(camera.status, systemImage: camera.tracking ? "circle.fill" : "circle").pill()
                Spacer()
                if camera.tracking { Text("\(Int(camera.fps)) fps").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            HStack {
                Button { if !drive.active { drive.startDrive() }; showDrive = true } label: {
                    Label(drive.active ? "\(fmtKm(drive.dist)) km · \(fmtDur(Date().timeIntervalSince(drive.startedAt ?? .now)))" : "Game Drive starten", systemImage: drive.active ? "stop.fill" : "play.fill")
                }.pill(active: drive.active)
                Spacer()
                Button { camera.setTracking(!camera.tracking) } label: { Label(camera.tracking ? "Tracking läuft" : "Tracken", systemImage: "scope") }.pill(active: camera.tracking)
            }
        }
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack {
            Button { showSightings = true } label: {
                HStack { Text("Sichtungen"); Text("\(sightings.reduce(0) { $0 + $1.n })").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor, in: Capsule()).foregroundStyle(.black) }
            }.pill()
            Spacer()
            ZoomSlider(camera: camera)
            Spacer()
            Button { photoAnalysis = true } label: { Image(systemName: "photo.on.rectangle") }.pill()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.pill()
        }
        .padding(.bottom, 10)
    }

    /// Tipp auf einen Rahmen öffnet die Korrektur (nur bei laufendem Tracking)
    private func tap(at p: CGPoint) {
        guard camera.tracking else { return }
        // Punkt aus Bildschirm- in Bildkoordinaten (die Vorschau füllt den Bildschirm mit Aspect-Fill)
        let screen = UIScreen.main.bounds.size
        let scale = max(screen.width / camera.frameSize.width, screen.height / camera.frameSize.height)
        let off = CGPoint(x: (camera.frameSize.width * scale - screen.width) / 2, y: (camera.frameSize.height * scale - screen.height) / 2)
        let img = CGPoint(x: (p.x + off.x) / scale, y: (p.y + off.y) / scale)
        if let t = camera.track(at: img, slack: 24 / scale) { correction = CorrectionTarget(trackId: t.id, predicted: t.name.replacingOccurrences(of: "?", with: ""), thumb: nil, sightingId: nil) }
    }
}

struct CorrectionTarget: Identifiable { let id = UUID(); let trackId: Int?; let predicted: String?; let thumb: Data?; let sightingId: UUID? }

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
    static let colors: [Color] = [Color(hex: 0xf0a93a), Color(hex: 0x5ec8f2), Color(hex: 0x9be36a), Color(hex: 0xf27ab0), Color(hex: 0xc9a3ff), Color(hex: 0x55e0c8), Color(hex: 0xffd166), Color(hex: 0xff9f6e)]
    var body: some View {
        GeometryReader { geo in
            let scale = max(geo.size.width / camera.frameSize.width, geo.size.height / camera.frameSize.height)
            let off = CGPoint(x: (camera.frameSize.width * scale - geo.size.width) / 2, y: (camera.frameSize.height * scale - geo.size.height) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(camera.tracks) { t in
                    let r = CGRect(x: t.box.minX * scale - off.x, y: t.box.minY * scale - off.y, width: t.box.width * scale, height: t.box.height * scale)
                    let color = Self.colors[t.colorIndex]
                    RoundedRectangle(cornerRadius: 10).strokeBorder(color, style: StrokeStyle(lineWidth: 2.2, dash: t.sure ? [] : [7, 5]))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    HStack(spacing: 7) { Text(t.name).font(.system(size: 14, weight: .semibold)); Text(t.sub).font(.system(size: 11, weight: .medium)).opacity(0.75) }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(t.sure ? color : Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(t.sure ? Color.black : Color.white)
                        .offset(x: r.minX, y: max(0, r.minY - 30))
                }
                if let h = camera.hint, CACurrentMediaTime() < h.until, camera.tracks.isEmpty {
                    Text("\(h.name)  \(Int(min(h.conf, 0.99) * 100)) %").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Self.colors[0], lineWidth: 1.5))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.62)
                }
            }
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
