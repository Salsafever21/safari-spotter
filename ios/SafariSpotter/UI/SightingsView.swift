import SwiftUI
import SwiftData
import MapKit

/// Sichtungen: Liste, Zählung, Karte (Route, Fotos, Sichtungen), Galerie, Prüfen
struct SightingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    @Query(sort: \Sighting.t, order: .reverse) private var sightings: [Sighting]
    @Query(sort: \PhotoItem.t, order: .reverse) private var photos: [PhotoItem]
    @Query(sort: \Drive.startedAt, order: .reverse) private var drives: [Drive]
    @Query(filter: #Predicate<Correction> { $0.status == "review" }) private var reviews: [Correction]
    @State private var tab = 0
    @State private var profile: SpeciesClass?
    @State private var correction: CorrectionTarget?
    @State private var viewer: PhotoItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Liste").tag(0); Text("Zählung").tag(1); Text("Karte").tag(2); Text("Galerie \(photos.count)").tag(3); Text("Prüfen \(reviews.count)").tag(4)
                }.pickerStyle(.segmented).padding()
                switch tab {
                case 0: list
                case 1: stats
                case 2: mapTab
                case 3: GalleryView(photos: photos, catalog: catalog)
                default: ReviewView(reviews: reviews)
                }
            }
            .navigationTitle("Sichtungen \(sightings.first.map { fmtDate($0.t) } ?? "heute")")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $profile) { c in ProfileView(cls: c) }
            .sheet(item: $correction) { t in CorrectionSheet(target: t, camera: camera) }
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
                    Stepper("\(s.n)", value: Binding(get: { s.n }, set: { v in if v <= 0 { context.delete(s) } else { s.n = v }; try? context.save() })).labelsHidden()
                    Text("\(s.n)").monospacedDigit().frame(width: 28)
                    Text(fmtTime(s.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Section {
                ShareLink(item: shareText) { Label("Liste teilen", systemImage: "square.and.arrow.up") }
                Button("Manuell eintragen") { correction = CorrectionTarget(trackId: nil, predicted: nil, thumb: nil, sightingId: nil) }
                Button("Liste leeren", role: .destructive) { sightings.forEach { context.delete($0) }; try? context.save() }
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

    // MARK: Karte
    private var mapTab: some View {
        let pts = drive.active ? drive.points : (drives.first?.points ?? [])
        let stats = drive.active ? drive.stats(sightings: sightings) : drives.first.map { DriveStats.compute(points: $0.points, startedAt: $0.startedAt, endedAt: $0.endedAt, dist: $0.dist, sightings: sightings) }
        return List {
            if let st = stats {
                HStack { tile(fmtKm(st.dist), "km"); tile(fmtDur(st.dur), "Dauer"); tile("\(Int(st.avgMoving * 3.6))", "km/h in Fahrt") }
                HStack { tile("\(st.stops.count)", "Stopps"); tile(fmtDur(st.standing), "Standzeit"); tile("\(Int(st.maxSpeed * 3.6))", "km/h max") }
            }
            Section("Karte mit Route, Fotos und Sichtungen") {
                Map {
                    if pts.count > 1 { MapPolyline(coordinates: pts.map { $0.coordinate }).stroke(Color.accentColor, lineWidth: 4) }
                    ForEach(photos.filter { $0.coordinate != nil }) { p in
                        Annotation(p.species.first ?? "Foto", coordinate: p.coordinate!) {
                            Button { viewer = p } label: {
                                if let d = p.thumb, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(p.coarse ? Color.red : Color.white, style: StrokeStyle(lineWidth: 2, dash: p.coarse ? [4] : []))) }
                            }
                        }
                    }
                    ForEach(sightings.filter { $0.coordinate != nil }) { s in
                        if s.coarse { MapCircle(center: s.coordinate!, radius: 10000).foregroundStyle(Color.red.opacity(0.08)).stroke(Color.red, lineWidth: 1.5) }
                        else { Annotation(s.name, coordinate: s.coordinate!) { Circle().fill(Color.green).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 1)) } }
                    }
                    if let f = drive.lastFix { Annotation("", coordinate: f.coordinate) { Circle().fill(Color.cyan).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2)) } }
                }.frame(height: 320)
                Text("Nashorn-Sichtungen erscheinen als 10-km-Kreis, ihre Fotos mit rotem Rand.").font(.caption).foregroundStyle(.secondary)
            }
            if let st = stats, !st.stops.isEmpty {
                Section("Stopps mit Sichtungen") {
                    ForEach(Array(st.stops.enumerated()), id: \.offset) { i, sp in
                        VStack(alignment: .leading) { HStack { Text("Stopp \(i + 1) · \(fmtTime(sp.t0))\(sp.open ? " (läuft)" : "")"); Spacer(); Text("\(fmtDur(sp.dur)) h").monospacedDigit() }
                            Text(sp.sightings.isEmpty ? "keine Sichtung" : sp.sightings.map { $0.name + ($0.n > 1 ? " \($0.n)×" : "") }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                if let url = Exporters.tempFile(Exporters.gpx(points: pts, sightings: sightings.reversed(), catalog: catalog, version: "1.0"), name: "safari.gpx") { ShareLink(item: url) { Label("GPX exportieren", systemImage: "map") } }
            }
            Section("Frühere Game Drives") {
                ForEach(drives) { d in let x = DriveStats.compute(points: d.points, startedAt: d.startedAt, endedAt: d.endedAt, dist: d.dist, sightings: sightings)
                    VStack(alignment: .leading) { HStack { Text("\(fmtDate(d.startedAt)) \(fmtTime(d.startedAt)) bis \(fmtTime(d.endedAt))"); Spacer(); Text("\(fmtKm(d.dist)) km").bold() }
                        Text("\(d.sightings) Tiere · \(x.stops.count) Stopps · \(fmtDur(x.standing)) h Stand · Ø \(Int(x.avgMoving * 3.6)) km/h").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .sheet(item: $viewer) { p in PhotoViewer(photo: p, photos: photos) }
    }
}

/// Galerie mit Vollbild-Viewer und "In Fotos sichern" (EXIF: Datum, GPS, Artnamen)
struct GalleryView: View {
    let photos: [PhotoItem]
    let catalog: SpeciesCatalog
    @Environment(\.modelContext) private var context
    @State private var viewer: PhotoItem?
    @State private var busy = false
    var body: some View {
        ScrollView {
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
                Button(busy ? "Sichere …" : "Alle in Fotos sichern") { Task { busy = true; for p in photos { try? await PhotoExporter.save(p, jpeg: PhotoExporter.jpegWithMetadata(p.image, date: p.t, coordinate: p.coordinate, description: "Safari Spotter: " + p.species.joined(separator: ", "))) }; busy = false } }.disabled(busy || photos.isEmpty)
                Button("Alle löschen", role: .destructive) { photos.forEach { context.delete($0) }; try? context.save() }
            }.buttonStyle(.bordered).padding()
            Text("Beim Sichern bekommt jedes Bild Datum, Standort und Artnamen als Bildinformation. In der Fotos-App erscheinen sie auf der Orte-Karte. Nashorn-Fotos tragen nur den 10-km-Standort.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
        .sheet(item: $viewer) { p in PhotoViewer(photo: p, photos: photos) }
    }
}

struct PhotoViewer: View {
    let photo: PhotoItem
    let photos: [PhotoItem]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var boxes = true
    @State private var saved = false
    var current: PhotoItem { photos.indices.contains(index) ? photos[index] : photo }
    var body: some View {
        VStack {
            HStack { VStack(alignment: .leading) { Text(current.species.joined(separator: ", ")).bold(); Text("\(fmtDate(current.t)) \(fmtTime(current.t)) · \(current.lat == nil ? "ohne Standort" : current.coarse ? "Standort ±10 km (Artenschutz)" : String(format: "GPS %.4f, %.4f", current.lat!, current.lon!)) · \(index + 1)/\(photos.count)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) } }.padding()
            if let ui = UIImage(data: current.image) {
                GeometryReader { geo in
                    let k = min(geo.size.width / CGFloat(current.width), geo.size.height / CGFloat(current.height))
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(width: CGFloat(current.width) * k, height: CGFloat(current.height) * k)
                        if boxes { ForEach(Array(current.dets.enumerated()), id: \.offset) { i, d in
                            RoundedRectangle(cornerRadius: 6).strokeBorder(OverlayView.colors[i % 8], style: StrokeStyle(lineWidth: 2, dash: d.sure ? [] : [6, 4])).frame(width: d.w * k, height: d.h * k).offset(x: d.x * k, y: d.y * k)
                            Text("\(d.name ?? "Tier") \(Int(min(d.conf, 0.99) * 100)) %").font(.caption.bold()).padding(4).background(OverlayView.colors[i % 8], in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black).offset(x: d.x * k, y: max(0, d.y * k - 22))
                        } }
                    }.frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in if v.translation.width < -40 { index = min(index + 1, photos.count - 1) } else if v.translation.width > 40 { index = max(index - 1, 0) } })
            }
            HStack {
                Button(saved ? "Gesichert" : "In Fotos sichern") { Task { try? await PhotoExporter.save(current, jpeg: PhotoExporter.jpegWithMetadata(current.image, date: current.t, coordinate: current.coordinate, description: "Safari Spotter: " + current.species.joined(separator: ", "))); saved = true } }.buttonStyle(.borderedProminent)
                Button(boxes ? "Rahmen aus" : "Rahmen ein") { boxes.toggle() }.buttonStyle(.bordered)
                Button("Löschen", role: .destructive) { context.delete(current); try? context.save(); dismiss() }.buttonStyle(.bordered)
            }.padding()
        }
        .onAppear { index = photos.firstIndex { $0.id == photo.id } ?? 0 }
        .onChange(of: index) { saved = false }
    }
}

/// Prüfliste: unsichere Treffer bestätigen oder korrigieren, Export als JSON für das Nachtraining
struct ReviewView: View {
    let reviews: [Correction]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var catalog: SpeciesCatalog
    @Query(filter: #Predicate<Correction> { $0.status != "review" }) private var done: [Correction]
    @State private var picking: Correction?
    var body: some View {
        List {
            Text("Unsichere Erkennungen landen hier. Bestätigen oder korrigieren, dann exportieren: Daraus lernt das Modell deine Safari.").font(.caption).foregroundStyle(.secondary)
            ForEach(reviews) { c in
                HStack(spacing: 12) {
                    if let ui = UIImage(data: c.image) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    VStack(alignment: .leading) {
                        Text(c.predicted ?? "unbestimmt").bold(); Text("\(Int((c.conf ?? 0) * 100)) % · \(fmtTime(c.t))").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("Richtig") { c.status = "confirmed"; c.label = c.predicted; c.labelKey = c.predKey; try? context.save() }.tint(.green)
                            Button("Falsch …") { picking = c }; Button("Löschen", role: .destructive) { context.delete(c); try? context.save() } }.buttonStyle(.bordered).font(.caption)
                    }
                }
            }
            Section {
                if let url = exportURL { ShareLink(item: url) { Label("Korrekturen exportieren (\(done.count) geprüft)", systemImage: "square.and.arrow.up") } }
                Button("Geprüfte löschen", role: .destructive) { done.forEach { context.delete($0) }; try? context.save() }
            }
        }
        .sheet(item: $picking) { c in SpeciesPicker(predicted: c.predicted) { name, key in c.status = "corrected"; c.label = name; c.labelKey = key; try? context.save() } }
    }
    private var exportURL: URL? {
        let items = done.map { ["img": "data:image/jpeg;base64," + $0.image.base64EncodedString(), "predicted": $0.predicted as Any, "predKey": $0.predKey as Any, "conf": $0.conf as Any, "label": $0.label as Any, "labelKey": $0.labelKey as Any, "status": $0.status, "t": $0.t.timeIntervalSince1970 * 1000, "region": $0.region as Any] }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["app": "Safari Spotter iOS", "exported": ISO8601DateFormatter().string(from: .now), "items": items]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("korrekturen.json")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
