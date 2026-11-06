import SwiftUI
import SwiftData
import MapKit
import UIKit

/// Sichtungen: Liste, Zählung, Karte (Route, Fotos, Sichtungen), Galerie, Prüfen
struct SightingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    @EnvironmentObject private var settings: AppSettings
    @Query(sort: \Sighting.t, order: .reverse) private var sightings: [Sighting]
    @Query(sort: \PhotoItem.t, order: .reverse) private var photos: [PhotoItem]
    @Query(sort: \Drive.startedAt, order: .reverse) private var drives: [Drive]
    @Query(filter: #Predicate<Correction> { $0.status == "review" }) private var reviews: [Correction]
    @State private var tab = 0
    @State private var profile: SpeciesClass?
    @State private var correction: CorrectionTarget?
    @State private var confirmClear = false
    @State private var storageError: String?
    @ObservedObject private var clipLibrary = ClipLibrary.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Liste").tag(0); Text("Zählung").tag(1); Text("Karte").tag(2); Text("Galerie \(photos.count + clipLibrary.clips.count)").tag(3); Text("Prüfen \(reviews.count)").tag(4)
                }.pickerStyle(.segmented).padding()
                switch tab {
                case 0: list
                case 1: stats
                case 2: mapTab
                case 3: GalleryView(photos: photos, catalog: catalog)
                default: ReviewView(reviews: reviews)
                }
            }
            .navigationTitle("Sichtungen (alle Tage)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $profile) { c in ProfileView(cls: c) }
            .sheet(item: $correction) { t in CorrectionSheet(target: t, camera: camera) }
            .confirmationDialog("Alle Sichtungen aus allen Tagen löschen?", isPresented: $confirmClear) {
                Button("Alle Sichtungen löschen", role: .destructive) {
                    sightings.forEach { context.delete($0) }
                    commit("Sichtungen löschen")
                }
            } message: {
                Text("Sichere die Daten vorher in Einstellungen → Daten sichern.")
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
                Button("OK") {}
            } message: { Text(storageError ?? "") }
        }
    }

    private func commit(_ action: String) {
        do { try context.save() }
        catch {
            context.rollback()
            storageError = "\(action) fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: Liste
    private var list: some View {
        List {
            if sightings.isEmpty { Text("Noch keine Sichtungen. Sobald ein Tier sicher erkannt wird, landet es hier.").foregroundStyle(.secondary) }
            ForEach(sightings) { s in
                HStack(spacing: 10) {
                    Button { correction = CorrectionTarget(trackId: nil, predicted: s.name, thumb: s.thumb, sightingId: s.id) } label: {
                        if let d = s.thumb, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8)) }
                        else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 44, height: 44).overlay(Text(s.src == "manual" ? "manuell" : "ohne Bild").font(.system(size: 9)).foregroundStyle(.secondary)) }
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading) {
                        Button(s.name) { profile = catalog.cls(name: s.name) ?? catalog.classes.first { $0.group == s.name } }.font(.headline).buttonStyle(.plain)
                        Text(s.lat == nil ? "ohne Standort" : s.coarse ? "Standort ±10 km (Artenschutz)" : "GPS ±\(Int(s.acc ?? 0)) m").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper("\(s.n)", value: Binding(get: { s.n }, set: { v in
                        if v <= 0 { context.delete(s) } else { s.n = v }
                        commit("Zählung speichern")
                    })).labelsHidden()
                    Text("\(s.n)").monospacedDigit().frame(width: 28)
                    Text(fmtTime(s.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Section {
                ShareLink(item: shareText) { Label("Liste teilen", systemImage: "square.and.arrow.up") }
                Button("Manuell eintragen") { correction = CorrectionTarget(trackId: nil, predicted: nil, thumb: nil, sightingId: nil) }
                Button("Alle Sichtungen löschen", role: .destructive) { confirmClear = true }
            }
        }
    }

    private var counts: [(String, Int)] {
        var m: [String: Int] = [:]; sightings.forEach { m[$0.name, default: 0] += $0.n }
        return m.sorted { $0.value > $1.value }
    }
    private var shareText: String {
        let total = counts.reduce(0) { $0 + $1.1 }
        return "Safari \(fmtDate(.now)): \(total) Tiere, \(counts.count) Arten\n" + counts.map { "\($0.0) \($0.1)×" }.joined(separator: "\n")
    }

    // MARK: Zählung
    private var stats: some View {
        List {
            HStack { tile("\(counts.reduce(0) { $0 + $1.1 })", "Tiere"); tile("\(counts.count)", "Arten"); tile(fmtKm(drive.active ? drive.dist : (drives.first?.dist ?? 0)), "km") }
            Section("Big Five") {
                let big5: [(String, (String) -> Bool)] = [("Elefant", { $0 == "Elefant" }), ("Nashorn", { $0.localizedCaseInsensitiveContains("nashorn") }), ("Büffel", { $0 == "Kaffernbüffel" }), ("Löwe", { $0.hasPrefix("Löw") }), ("Leopard", { $0 == "Leopard" })]
                HStack { ForEach(big5, id: \.0) { b in let done = counts.contains { b.1($0.0) }; Text(b.0).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8).background(done ? Color.green.opacity(0.2) : Color.clear).overlay(RoundedRectangle(cornerRadius: 8).stroke(done ? Color.green : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: done ? [] : [4]))) } }
            }
            Section("Pro Art") { ForEach(counts, id: \.0) { c in HStack { Text(c.0); Spacer(); Text("\(c.1)").monospacedDigit().bold() } } }
            Section {
                if let url = Exporters.tempFile(Exporters.csv(sightings: sightings.reversed(), catalog: catalog), name: "sichtungen.csv") { ShareLink(item: url) { Label("CSV exportieren", systemImage: "tablecells") } }
            }
        }
    }
    private func tile(_ v: String, _ l: String) -> some View { VStack { Text(v).font(.title2.monospacedDigit().bold()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }

    // MARK: Karte und Fahrtenhistorie
    private var mapTab: some View {
        DriveHistoryView(sightings: sightings, photos: photos, drives: drives)
    }

}

/// Galerie mit Vollbild-Viewer und "In Fotos sichern" (EXIF: Datum, GPS, Artnamen)
struct GalleryView: View {
    let photos: [PhotoItem]
    let catalog: SpeciesCatalog
    @Environment(\.modelContext) private var context
    @State private var viewer: PhotoItem?
    @State private var busy = false
    @State private var exportError: String?
    @State private var confirmDelete = false
    @ObservedObject private var clipLibrary = ClipLibrary.shared
    var body: some View {
        ScrollView {
            ClipGrid(library: clipLibrary)
            if photos.isEmpty { Text("Noch keine Fotos. Bei jeder neuen Sichtung speichert die App einen Schnappschuss.").foregroundStyle(.secondary).padding() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(photos) { p in
                    Button { viewer = p } label: {
                        ZStack(alignment: .bottomLeading) {
                            if let d = p.thumb, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill() }
                            Text(p.species.first ?? (p.kind == "photo" ? "Bild" : "Foto")).font(.caption.bold()).padding(6).shadow(radius: 3)
                        }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.padding(.horizontal)
            HStack {
                Button(busy ? "Sichere …" : "Alle in Fotos sichern") {
                    Task {
                        busy = true; defer { busy = false }
                        do { for p in photos { try await PhotoExporter.export(p, isSensitive: { catalog.isSensitive(name: $0) }) } }
                        catch { exportError = error.localizedDescription }
                    }
                }.disabled(busy || photos.isEmpty)
                Button("Alle löschen", role: .destructive) { confirmDelete = true }
            }.buttonStyle(.bordered).padding()
            Text("Beim Sichern bekommt jedes Bild Datum, Standort und Artnamen als Bildinformation. In der Fotos-App erscheinen sie auf der Orte-Karte. Nashorn-Fotos tragen nur den 10-km-Standort.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
        .sheet(item: $viewer) { p in PhotoViewer(photo: p, photos: photos) }
        .confirmationDialog("Alle Fotos aus der App löschen?", isPresented: $confirmDelete) {
            Button("Alle Fotos löschen", role: .destructive) {
                photos.forEach { context.delete($0) }
                do { try context.save() }
                catch { context.rollback(); exportError = "Fotos konnten nicht gelöscht werden: \(error.localizedDescription)" }
            }
        } message: { Text("Sichere die Daten vorher in Einstellungen → Daten sichern.") }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK") {} } message: { Text(exportError ?? "") }
    }
}

struct PhotoViewer: View {
    let photo: PhotoItem
    let photos: [PhotoItem]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: SpeciesCatalog
    @State private var index = 0
    @State private var boxes = true
    @State private var saved = false
    @State private var exportError: String?
    @State private var confirmDelete = false
    var current: PhotoItem { photos.indices.contains(index) ? photos[index] : photo }
    var body: some View {
        VStack {
            HStack { VStack(alignment: .leading) { Text(current.species.joined(separator: ", ")).bold(); Text("\(fmtDate(current.t)) \(fmtTime(current.t)) · \(current.lat == nil ? "ohne Standort" : current.coarse ? "Standort ±10 km (Artenschutz)" : String(format: "GPS %.4f, %.4f", current.lat!, current.lon!)) · \(index + 1)/\(photos.count)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) } }.padding()
            if let ui = UIImage(data: current.image) {
                GeometryReader { geo in
                    let width = CGFloat(current.width > 0 ? current.width : max(1, Int(ui.size.width * ui.scale)))
                    let height = CGFloat(current.height > 0 ? current.height : max(1, Int(ui.size.height * ui.scale)))
                    let k = min(geo.size.width / width, geo.size.height / height)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(width: width * k, height: height * k)
                        if boxes { ForEach(Array(current.dets.enumerated()), id: \.offset) { i, d in
                            RoundedRectangle(cornerRadius: 6).strokeBorder(OverlayView.colors[i % 8], style: StrokeStyle(lineWidth: 2, dash: d.sure ? [] : [6, 4])).frame(width: d.w * k, height: d.h * k).offset(x: d.x * k, y: d.y * k)
                            Text("\(d.name ?? "Tier") \(Int(min(d.conf, 0.99) * 100)) %").font(.caption.bold()).padding(4).background(OverlayView.colors[i % 8], in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black).offset(x: d.x * k, y: max(0, d.y * k - 22))
                        } }
                    }.frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in if v.translation.width < -40 { index = min(index + 1, photos.count - 1) } else if v.translation.width > 40 { index = max(index - 1, 0) } })
            } else {
                Text("Dieses Foto kann nicht angezeigt werden. Die gespeicherten Originaldaten bleiben erhalten.")
                    .foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button(saved ? "Gesichert" : "In Fotos sichern") {
                    let item = current
                    Task {
                        do { try await PhotoExporter.export(item, isSensitive: { catalog.isSensitive(name: $0) }); saved = true }
                        catch { exportError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                Button(boxes ? "Rahmen aus" : "Rahmen ein") { boxes.toggle() }.buttonStyle(.bordered)
                Button("Löschen", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
            }.padding()
        }
        .onAppear { index = photos.firstIndex { $0.id == photo.id } ?? 0 }
        .onChange(of: index) { saved = false }
        .confirmationDialog("Dieses Foto aus der App löschen?", isPresented: $confirmDelete) {
            Button("Foto löschen", role: .destructive) {
                context.delete(current)
                do { try context.save(); dismiss() }
                catch { context.rollback(); exportError = "Foto konnte nicht gelöscht werden: \(error.localizedDescription)" }
            }
        }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK") {} } message: { Text(exportError ?? "") }
    }
}

/// Prüfliste: unsichere Treffer bestätigen oder korrigieren, Export als JSON für das Nachtraining
struct ReviewView: View {
    let reviews: [Correction]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var catalog: SpeciesCatalog
    @Query(filter: #Predicate<Correction> { $0.status != "review" }) private var done: [Correction]
    @State private var activeSheet: ReviewSheet?
    @State private var exportedURL: URL?
    @State private var storageError: String?
    @State private var confirmDeleteDone = false
    var body: some View {
        List {
            Text("Unsichere Erkennungen landen hier. Geprüfte Bildausschnitte kannst du exportieren und später auf dem Mac für ein neues Artenmodell verwenden.").font(.caption).foregroundStyle(.secondary)
            ForEach(reviews) { c in
                HStack(spacing: 12) {
                    if let ui = UIImage(data: c.image) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    VStack(alignment: .leading) {
                        Text(c.predicted ?? "unbestimmt").bold(); Text("\(Int((c.conf ?? 0) * 100)) % · \(fmtTime(c.t))").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("Richtig") { c.status = "confirmed"; c.label = c.predicted; c.labelKey = c.predKey; commit("Prüfung speichern") }.tint(.green)
                            Button("Falsch …") { activeSheet = .picker(c) }; Button("Löschen", role: .destructive) { context.delete(c); commit("Prüfung löschen") } }.buttonStyle(.bordered).font(.caption)
                    }
                }
            }
            Section {
                Button { exportCorrections() } label: {
                    Label("Korrekturen exportieren (\(done.count) geprüft)", systemImage: "square.and.arrow.up")
                }.disabled(done.isEmpty)
                Button("Geprüfte löschen", role: .destructive) { confirmDeleteDone = true }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .picker(let c):
                SpeciesPicker(predicted: c.predicted) { name, key in
                    c.status = "corrected"; c.label = name; c.labelKey = key; commit("Korrektur speichern")
                }
            case .share(let url):
                FileShareSheet(url: url) { completeExport(url) }
                    .interactiveDismissDisabled()
            }
        }
        .confirmationDialog("Alle geprüften Einträge löschen?", isPresented: $confirmDeleteDone) {
            Button("Geprüfte löschen", role: .destructive) { done.forEach { context.delete($0) }; commit("Geprüfte Einträge löschen") }
        }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
            Button("OK") {}
        } message: { Text(storageError ?? "") }
    }
    private func commit(_ action: String) {
        do { try context.save() }
        catch { context.rollback(); storageError = "\(action) fehlgeschlagen: \(error.localizedDescription)" }
    }
    private func exportCorrections() {
        do {
            try? CorrectionExporter.removeStale()
            let url = try CorrectionExporter.create(done)
            exportedURL = url
            activeSheet = .share(url)
        } catch { storageError = "Korrekturen konnten nicht exportiert werden: \(error.localizedDescription)" }
    }
    private func completeExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if exportedURL == url { exportedURL = nil }
        if case .share(let shown) = activeSheet, shown == url { activeSheet = nil }
    }
}

private enum ReviewSheet: Identifiable {
    case picker(Correction)
    case share(URL)
    var id: String {
        switch self {
        case .picker(let correction): return "picker-" + correction.id.uuidString
        case .share(let url): return "share-" + url.lastPathComponent
        }
    }
}

struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onComplete() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
