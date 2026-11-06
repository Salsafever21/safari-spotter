import SwiftUI
import SwiftData
import MapKit
import UIKit
import Combine

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
    @State private var historyFilter = SightingHistoryFilter()
    @State private var referenceDate = Date.now
    @State private var csvShare: SightingCSVShare?
    @FocusState private var searchFocused: Bool
    @State private var profile: SpeciesClass?
    @State private var correction: CorrectionTarget?
    @State private var confirmClear = false
    @State private var sightingToDelete: Sighting?
    @State private var storageError: String?
    @ObservedObject private var clipLibrary = ClipLibrary.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Liste").tag(0); Text("Zählung").tag(1); Text("Karte").tag(2); Text("Galerie \(photos.count + clipLibrary.clips.count)").tag(3); Text("Prüfen \(reviews.count)").tag(4)
                }.pickerStyle(.segmented).padding()
                if tab == 0 || tab == 1 { filterBar }
                switch tab {
                case 0: list
                case 1: stats
                case 2: mapTab
                case 3: GalleryView(photos: photos, catalog: catalog)
                default: ReviewView(reviews: reviews)
                }
            }
            .navigationTitle("Sichtungen")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { referenceDate = .now }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in referenceDate = .now }
            .sheet(item: $csvShare) { item in
                FileShareSheet(url: item.url) {
                    try? FileManager.default.removeItem(at: item.url)
                    csvShare = nil
                }.interactiveDismissDisabled()
            }
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
            .alert("Sichtung löschen?", isPresented: Binding(
                get: { sightingToDelete != nil }, set: { if !$0 { sightingToDelete = nil } }),
                presenting: sightingToDelete) { sighting in
                Button("Sichtung löschen", role: .destructive) {
                    do { try SightingStore(context: context, catalog: catalog).remove(sighting) }
                    catch { storageError = "Sichtung konnte nicht gelöscht werden: \(error.localizedDescription)" }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { sighting in
                Text("\(sighting.name) (Anzahl: \(sighting.n)) entfernen? Zugehörige Fotos bleiben in der Galerie.")
            }
            .alert("Aktion fehlgeschlagen", isPresented: Binding(get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
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

    private var filteredSightings: [Sighting] { historyFilter.apply(to: sightings, now: referenceDate) }
    private var counts: [(String, Int)] { SightingHistoryFilter.counts(filteredSightings).map { ($0.name, $0.count) } }
    private var shareText: String { historyFilter.shareText(sightings: sightings, now: referenceDate) }

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("Zeitraum", selection: $historyFilter.scope) {
                ForEach(SightingDateScope.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if historyFilter.scope == .day {
                DatePicker("Datum", selection: $historyFilter.selectedDay, displayedComponents: .date)
            }
            HStack {
                TextField("Art suchen", text: $historyFilter.query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("sighting-species-search")
                if !historyFilter.query.isEmpty {
                    Button { historyFilter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Artfilter löschen")
                }
            }
            HStack {
                Text("\(historyFilter.title(now: referenceDate)) · \(filteredSightings.count) von \(sightings.count) Einträgen")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sighting-filter-summary")
                Spacer()
                if historyFilter.scope != .all || !historyFilter.query.isEmpty {
                    Button("Alle anzeigen", action: resetFilter).font(.caption)
                        .accessibilityIdentifier("sighting-filter-reset")
                }
            }
        }.padding(.horizontal).padding(.bottom, 8)
    }

    private func resetFilter() { historyFilter.scope = .all; historyFilter.query = ""; searchFocused = false }

    // MARK: Liste
    private var list: some View {
        List {
            if filteredSightings.isEmpty {
                Text(sightings.isEmpty ? "Noch keine Sichtungen. Sobald ein Tier sicher erkannt wird, landet es hier."
                     : "Keine Sichtungen für diese Auswahl. Über Alle anzeigen erreichst du die übrigen Tage.")
                    .foregroundStyle(.secondary)
            }
            ForEach(SightingHistoryFilter.days(filteredSightings)) { day in
                Section(SightingHistoryFilter.dateLabel(day.date)) {
                    ForEach(day.sightings) { s in sightingRow(s) }
                }
            }
            Section {
                ShareLink(item: shareText) { Label("Ausgewählte Liste teilen", systemImage: "square.and.arrow.up") }
                    .disabled(filteredSightings.isEmpty)
                Button("Sichtung für heute eintragen") {
                    historyFilter.scope = .today; historyFilter.query = ""
                    referenceDate = .now
                    correction = CorrectionTarget(trackId: nil, predicted: nil, thumb: nil, sightingId: nil)
                }
                if historyFilter.scope == .all && historyFilter.query.isEmpty {
                    Button("Alle Sichtungen löschen", role: .destructive) { confirmClear = true }
                        .disabled(sightings.isEmpty)
                }
            }
        }
    }

    private func sightingRow(_ s: Sighting) -> some View {
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
                do { try SightingStore(context: context, catalog: catalog).setCount(v, for: s) }
                catch { storageError = "Zählung konnte nicht gespeichert werden: \(error.localizedDescription)" }
            }), in: 1...Int.max).labelsHidden()
                .accessibilityLabel("\(s.name) zählen")
                .accessibilityIdentifier("sighting-count-\(s.name)")
            Text("\(s.n)").monospacedDigit().frame(width: 28)
            Text(fmtTime(s.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .swipeActions(allowsFullSwipe: false) {
            Button("Löschen", role: .destructive) { sightingToDelete = s }
                .accessibilityIdentifier("sighting-delete-\(s.name)")
        }
    }

    private func exportCSV() {
        do {
            try TextShareFile.removeStale()
            let content = Exporters.csv(sightings: filteredSightings.reversed(), catalog: catalog,
                                        privacySightings: sightings, privacyPhotos: photos)
            csvShare = SightingCSVShare(url: try TextShareFile.create(content, kind: .sightings, extension: "csv"))
        } catch { storageError = "CSV konnte nicht erstellt werden: \(error.localizedDescription)" }
    }

    // MARK: Zählung
    private var stats: some View {
        List {
            HStack { tile("\(counts.reduce(0) { $0 + $1.1 })", "Tiere"); tile("\(counts.count)", "Arten"); tile("\(filteredSightings.count)", "Einträge") }
            Section("Big Five") {
                let big5: [(String, (String) -> Bool)] = [("Elefant", { $0 == "Elefant" }), ("Nashorn", { $0.localizedCaseInsensitiveContains("nashorn") }), ("Büffel", { $0 == "Kaffernbüffel" }), ("Löwe", { $0.hasPrefix("Löw") }), ("Leopard", { $0 == "Leopard" })]
                HStack { ForEach(big5, id: \.0) { b in let done = counts.contains { b.1($0.0) }; Text(b.0).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8).background(done ? Color.green.opacity(0.2) : Color.clear).overlay(RoundedRectangle(cornerRadius: 8).stroke(done ? Color.green : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: done ? [] : [4]))) } }
            }
            Section("Pro Art") { ForEach(counts, id: \.0) { c in HStack { Text(c.0); Spacer(); Text("\(c.1)").monospacedDigit().bold() } } }
            Section {
                Button(action: exportCSV) { Label("Auswahl als CSV teilen", systemImage: "tablecells") }.disabled(filteredSightings.isEmpty)
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
    @State private var exportError: String?
    @State private var confirmDelete = false
    @ObservedObject private var exporter = PhotoExportController.shared
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
                Button(exporter.isRunning ? "Sichere …" : "Alle in Fotos sichern") {
                    exporter.start(photos: photos, context: context, catalog: catalog)
                }.disabled(exporter.isRunning || photos.isEmpty)
                Button("Alle löschen", role: .destructive) { confirmDelete = true }
                    .disabled(exporter.isRunning || photos.isEmpty)
            }.buttonStyle(.bordered).padding()
            PhotoExportStatusView(exporter: exporter).padding(.horizontal).padding(.bottom, 8)
            Text("Beim Sichern bekommt jedes Bild Datum, Standort und Artnamen als Bildinformation. Nashorn-Fotos und andere Fotos innerhalb von 15 Minuten erhalten einen 10-km-Standort und eine auf die Stunde gerundete Aufnahmezeit.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
        .sheet(item: $viewer) { p in PhotoViewer(photo: p, photos: photos) }
        .confirmationDialog("Alle Fotos aus der App löschen?", isPresented: $confirmDelete) {
            Button("Alle Fotos löschen", role: .destructive) {
                guard !exporter.isRunning else { return }
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
    @State private var exportError: String?
    @State private var confirmDelete = false
    @ObservedObject private var exporter = PhotoExportController.shared
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
                Button(exporter.savedIDs.contains(current.id) ? "Erneut sichern" : "In Fotos sichern") {
                    exporter.start(photos: [current], context: context, catalog: catalog)
                }.buttonStyle(.borderedProminent).disabled(exporter.isRunning)
                Button(boxes ? "Rahmen aus" : "Rahmen ein") { boxes.toggle() }.buttonStyle(.bordered)
                Button("Löschen", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
                    .disabled(exporter.isRunning)
            }.padding()
            if exporter.savedIDs.contains(current.id) {
                Text("Dieses Foto wurde in der Mediathek gesichert.").font(.caption).foregroundStyle(.secondary)
            }
            PhotoExportStatusView(exporter: exporter).padding(.horizontal).padding(.bottom)
        }
        .onAppear { index = photos.firstIndex { $0.id == photo.id } ?? 0 }
        .confirmationDialog("Dieses Foto aus der App löschen?", isPresented: $confirmDelete) {
            Button("Foto löschen", role: .destructive) {
                guard !exporter.isRunning else { return }
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

private struct SightingCSVShare: Identifiable { let url: URL; var id: URL { url } }
