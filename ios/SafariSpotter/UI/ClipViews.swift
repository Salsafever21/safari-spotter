import SwiftUI
import AVKit

/// Videos in der Galerie: Vorschaubild, Dauer, Hinweis bei unvollständigen Clips
struct ClipGrid: View {
    @ObservedObject var library: ClipLibrary
    @State private var playing: ClipRecord?
    var body: some View {
        if !library.clips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Videos \(library.clips.count)").font(.headline).padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(library.clips) { clip in
                        Button { playing = clip } label: {
                            ZStack(alignment: .bottomLeading) {
                                if let ui = library.thumbnail(clip) { Image(uiImage: ui).resizable().scaledToFill() }
                                else { Rectangle().fill(.quaternary) }
                                HStack(spacing: 4) {
                                    Image(systemName: clip.isPlayable ? "video.fill" : "exclamationmark.triangle.fill")
                                    Text(clip.isPlayable ? VideoGeometry.timerText(clip.duration) : "beschädigt")
                                }
                                .font(.caption.bold()).padding(6).shadow(radius: 3)
                            }
                            .frame(height: 110).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel("Video \(fmtDate(clip.createdAt)) \(fmtTime(clip.createdAt)), \(VideoGeometry.timerText(clip.duration))")
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .sheet(item: $playing) { clip in ClipPlayerView(clip: clip, library: library) }
        }
    }
}

/// Abspielen, Teilen, in Fotos sichern, Löschen (mit Rückfrage)
struct ClipPlayerView: View {
    let clip: ClipRecord
    @ObservedObject var library: ClipLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let player { VideoPlayer(player: player).frame(maxHeight: .infinity) }
                else { Text("Video nicht gefunden").foregroundStyle(.secondary).frame(maxHeight: .infinity) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.species.isEmpty ? "Video" : clip.species.joined(separator: ", ")).bold()
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                HStack {
                    if let url = library.movieURL(clip), clip.isPlayable {
                        ShareLink(item: url) { Label("Teilen", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                    }
                    Button(saved ? "Gesichert" : saving ? "Sichere …" : "In Fotos sichern") { save() }
                        .buttonStyle(.borderedProminent).disabled(saving || saved || !clip.isPlayable)
                    Button("Löschen", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
                }
                .padding(.bottom)
            }
            .navigationTitle("\(fmtDate(clip.createdAt)) \(fmtTime(clip.createdAt))").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .onAppear { if let url = library.movieURL(clip), clip.isPlayable { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
            .confirmationDialog("Dieses Video löschen?", isPresented: $confirmDelete) {
                Button("Video löschen", role: .destructive) {
                    do { try library.delete(clip); dismiss() } catch { message = error.localizedDescription }
                }
            } message: { Text("Das Video wird nur in Safari Spotter gelöscht; bereits in Fotos gesicherte Kopien bleiben.") }
            .alert("Video", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
        }
    }

    private var details: String {
        var parts = [VideoGeometry.timerText(clip.duration), "\(clip.width)×\(clip.height)",
                     ByteCountFormatter.string(fromByteCount: clip.fileSize, countStyle: .file)]
        if clip.burnedIn { parts.append("mit Rahmen") }
        parts.append(clip.lat == nil ? "ohne Standort" : "Standort ±10 km")
        if clip.state == .recovered { parts.append("nach Abbruch wiederhergestellt") }
        if clip.state == .damaged { parts.append("beschädigt") }
        return parts.joined(separator: " · ")
    }

    private func save() {
        guard let url = library.movieURL(clip) else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await VideoExporter.saveToPhotos(clip, url: url); saved = true }
            catch { message = error.localizedDescription }
        }
    }
}
