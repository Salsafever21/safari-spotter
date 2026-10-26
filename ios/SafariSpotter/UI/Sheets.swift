import SwiftUI
import SwiftData
import PhotosUI
import CoreImage
import MapKit

/// Artenwahl (Korrektur, manueller Eintrag, Prüfliste)
struct SpeciesPicker: View {
    let predicted: String?
    let onPick: (String, String) -> Void      // (Anzeigename, Schlüssel; "group:X", "__other", "__none")
    @EnvironmentObject private var catalog: SpeciesCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var options: [(String, String)] {
        var o = catalog.shownClasses.map { ($0.name, $0.key) }
        for g in Set(catalog.classes.compactMap { $0.group }) { o.append((g + " (Art unklar)", "group:" + g)) }
        o.sort { $0.0.localizedCompare($1.0) == .orderedAscending }
        o += [("Anderes Tier (kein Safari-Tier)", "__other"), ("Kein Tier (Fehlalarm)", "__none")]
        return search.isEmpty ? o : o.filter { $0.0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List(options, id: \.1) { o in
                Button { onPick(o.1 == "__other" ? "Anderes Tier" : o.1 == "__none" ? "Kein Tier" : o.1.hasPrefix("group:") ? String(o.1.dropFirst(6)) : o.0, o.1); dismiss() } label: { HStack { Text(o.0); if o.0 == predicted { Spacer(); Image(systemName: "checkmark") } } }
            }
            .searchable(text: $search, prompt: "Art suchen")
            .navigationTitle(predicted.map { "Erkannt: \($0)" } ?? "Art wählen")
            .toolbar { Button("Abbrechen") { dismiss() } }
        }
    }
}

/// Korrektur eines Tracks, einer Sichtung oder manueller Eintrag
struct CorrectionSheet: View {
    let target: CorrectionTarget
    @ObservedObject var camera: CameraController
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    var body: some View {
        SpeciesPicker(predicted: target.predicted) { name, key in
            let isNone = key == "__none", isOther = key == "__other"
            if let sid = target.sightingId, let s = try? context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.id == sid })).first {
                if isNone { context.delete(s) } else { rename(s, to: name, key: key) }
            } else if let tid = target.trackId {
                camera.correct(trackId: tid, name: name, key: key, isNone: isNone, isOther: isOther)
                if !isNone, !isOther { camera.log(name: name, key: key, thumb: target.thumb, src: "cam", image: nil, size: .zero, noMerge: true) }
            } else if !isNone {
                camera.log(name: name, key: key, thumb: nil, src: "manual", image: nil, size: .zero, noMerge: true)
            }
            if let img = target.thumb, let predicted = target.predicted {
                context.insert(Correction(image: img, predicted: predicted, predKey: catalog.cls(name: predicted)?.key, conf: nil, label: name, labelKey: key, status: predicted == name ? "confirmed" : "corrected", region: drive.autoRegion?.key))
            }
            try? context.save()
        }
    }
    private func rename(_ s: Sighting, to name: String, key: String) {
        s.name = name; s.key = key
        if catalog.isSensitive(name: name), let lat = s.lat, let lon = s.lon, !s.coarse { let c = Position.coarsen(lat: lat, lon: lon); s.lat = c.lat; s.lon = c.lon; s.acc = 10000; s.coarse = true }
    }
}

/// Steckbrief
struct ProfileView: View {
    let cls: SpeciesClass
    @EnvironmentObject private var catalog: SpeciesCatalog
    var body: some View {
        let i = catalog.info[cls.key]
        List {
            Text(((i?.latin ?? cls.latin) ?? "") + (i?.en.map { " · " + $0 } ?? "")).italic().foregroundStyle(.secondary)
            if i?.big5 == true { row("Big Five", "Ja") }
            row("Erkennen", i?.id); row("Verwechslung", i?.confuse); row("Grösse", [i?.size, i?.weight].compactMap { $0 }.joined(separator: ", ")); row("Lebensweise", i?.habits); row("Rote Liste", i?.status)
            if cls.sensitive { row("Artenschutz", "Standorte dieser Art speichert die App nur auf 10 km genau und gibt sie nie exakt weiter.") }
        }.navigationTitle(cls.name)
    }
    @ViewBuilder private func row(_ k: String, _ v: String?) -> some View { if let v, !v.isEmpty { VStack(alignment: .leading, spacing: 2) { Text(k.uppercased()).font(.caption2).foregroundStyle(.secondary); Text(v) } } }
}

/// Game Drive live (Strava-Stil): Uhr, km, Tempo, Karte mit wachsender Route, Statistik, Splits
struct DriveLiveView: View {
    let sightings: [Sighting]
    @EnvironmentObject private var drive: DriveRecorder
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = 0
    var body: some View {
        let st = drive.stats(sightings: sightings)
        NavigationStack {
            List {
                HStack(alignment: .lastTextBaseline) {
                    big(fmtClock(st?.dur ?? 0), "Dauer"); big(fmtKm(st?.dist ?? 0), "km"); big("\(Int(max(0, drive.lastFix?.speed ?? 0) * 3.6))", "km/h jetzt")
                }
                if let st { Text(st.stops.last?.open == true ? "Auto-Pause: steht seit \(fmtDur(st.stops.last!.dur)) h" : "In Fahrt").font(.caption).foregroundStyle(.secondary) }
                Map(position: $position) {
                    if drive.points.count > 1 { MapPolyline(coordinates: drive.points.map { $0.coordinate }).stroke(Color.accentColor, lineWidth: 5) }
                    UserAnnotation()
                }.frame(height: 260).mapControls { MapUserLocationButton() }
                if let st {
                    HStack { tile(fmtDur(st.moving), "in Fahrt"); tile(fmtDur(st.standing), "Standzeit"); tile("\(st.stops.count)", "Stopps") }
                    HStack { tile("\(Int(st.avgMoving * 3.6))", "km/h in Fahrt"); tile("\(Int(st.maxSpeed * 3.6))", "km/h max"); tile("\(Int(st.elev))", "Höhenmeter") }
                    Section("Kilometer-Splits") { ForEach(Array(st.splits.enumerated()), id: \.offset) { _, sp in HStack { Text("km \(sp.km) · \(fmtTime(sp.at))"); Spacer(); Text("\(fmtClock(sp.time).dropFirst(2)) · \(Int(3600 / max(1, sp.time))) km/h").monospacedDigit() } } }
                }
                Section {
                    Button("Game Drive beenden", role: .destructive) {
                        if let d = drive.stopDrive(sightingsCount: sightings.filter { $0.t >= (drive.startedAt ?? .now) }.reduce(0) { $0 + $1.n }) { context.insert(d); try? context.save() }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Game Drive").navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in tick += 1 }
        }
    }
    private func big(_ v: String, _ l: String) -> some View { VStack(alignment: .leading) { Text(v).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func tile(_ v: String, _ l: String) -> some View { VStack { Text(v).font(.title3.monospacedDigit().bold()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}

/// Einstellungen
struct SettingsView: View {
    @ObservedObject var camera: CameraController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    var body: some View {
        NavigationStack {
            Form {
                Section("Erkennung") {
                    VStack(alignment: .leading) { Text("Empfindlichkeit: Schwelle \(Int(settings.threshold * 100)) %"); Slider(value: $settings.threshold, in: 0.25...0.75, step: 0.05) }
                    Toggle("Namen einblenden", isOn: $settings.labels)
                    Picker("Fernerkennung", selection: $settings.far) { Text("Aus").tag("off"); Text("Normal (4 Kacheln)").tag("on"); Text("Stark (9 Kacheln)").tag("max") }
                    Picker("Region als Vorwissen", selection: $settings.region) { Text("Automatisch (GPS)").tag("auto"); Text("Keine Region").tag("none"); ForEach(catalog.regions) { Text($0.name).tag($0.key) } }
                    Text(drive.currentRegion(setting: settings.region).map { "Aktiv: " + $0.name } ?? "Kein Vorwissen aktiv").font(.caption).foregroundStyle(.secondary)
                    Toggle("Tracken beim Kamerastart", isOn: $settings.autoTrack)
                    Toggle("Schnappschuss bei Sichtung", isOn: $settings.snapshots)
                    Toggle("Unsichere Treffer sammeln", isOn: $settings.collect)
                }
                Section("Kamera") { Picker("Auflösung", selection: $settings.res) { Text("HD 720p").tag("720"); Text("Full HD 1080p").tag("1080"); Text("4K 2160p").tag("2160") }; Text("Gilt ab dem nächsten App-Start.").font(.caption).foregroundStyle(.secondary) }
                Section { Text("Safari Spotter iOS · Artenmodell v\(catalog.modelVersion) · \(catalog.shownClasses.count) Arten").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Einstellungen")
        }
    }
}

/// Bilder aus der Mediathek analysieren (EXIF-Standort und -Zeit werden übernommen)
struct PhotoAnalysisView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    @EnvironmentObject private var settings: AppSettings
    @State private var picked: [PhotosPickerItem] = []
    @State private var result: (image: UIImage, dets: [PhotoDet], meta: (date: Date?, coord: CLLocationCoordinate2D?))?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            VStack {
                PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) { Label("Bilder auswählen", systemImage: "photo.on.rectangle") }.buttonStyle(.borderedProminent)
                if busy { ProgressView("Analysiere …") }
                if let r = result {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: r.image).resizable().scaledToFit()
                    }
                    List(Array(r.dets.enumerated()), id: \.offset) { _, d in HStack { Text(d.name ?? "Tier").bold(); Spacer(); Text("\(Int(min(d.conf, 0.99) * 100)) %") } }
                    Button("Als Sichtung speichern") { save(r) }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .navigationTitle("Bildanalyse").toolbar { Button("Fertig") { dismiss() } }
            .onChange(of: picked) { Task { await analyze() } }
        }
    }
    private func analyze() async {
        guard let item = picked.first, let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) else { return }
        busy = true; defer { busy = false }
        // EXIF
        var date: Date? = nil, coord: CLLocationCoordinate2D? = nil
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], let lat = g[kCGImagePropertyGPSLatitude] as? Double, let lon = g[kCGImagePropertyGPSLongitude] as? Double {
                coord = CLLocationCoordinate2D(latitude: (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat, longitude: (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon)
            }
            if let e = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = e[kCGImagePropertyExifDateTimeOriginal] as? String { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; date = f.date(from: s) }
        }
        guard let pipeline = try? VisionPipeline(catalog: catalog), let cg = ui.cgImage else { return }
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(ui.imageOrientation.exifValue))
        let size = ci.extent.size
        let region = drive.currentRegion(setting: settings.region)
        var dets: [PhotoDet] = []
        if let raw = try? pipeline.detectAll(in: ci, visible: CGRect(origin: .zero, size: size), threshold: settings.threshold, tiles: 3) {
            for d in raw.prefix(10) {
                let sq = VisionPipeline.cropSquare(d.box, in: size)
                let dec = (try? pipeline.classify(ci, square: sq, region: region)).map { SpeciesDecision.decide($0, catalog: catalog) } ?? SpeciesDecision(name: nil, key: nil, confidence: 0, sure: false, other: false)
                guard d.firm || (dec.name != nil && !dec.other && dec.confidence >= 0.5) else { continue }
                if let n = dec.name, dets.contains(where: { $0.name == n && VisionPipeline.iou(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), d.box) > 0.12 }) { continue }
                dets.append(PhotoDet(x: d.box.minX, y: d.box.minY, w: d.box.width, h: d.box.height, name: dec.name, conf: dec.confidence, sure: dec.sure))
            }
        }
        result = (ui, dets, (date, coord))
    }
    private func save(_ r: (image: UIImage, dets: [PhotoDet], meta: (date: Date?, coord: CLLocationCoordinate2D?))) {
        var ids: [UUID] = [], names: [String] = []
        var counts: [String: (Int, String?)] = [:]
        for d in r.dets { if let n = d.name { counts[n] = ((counts[n]?.0 ?? 0) + 1, catalog.cls(name: n)?.key) } }
        for (name, (n, key)) in counts {
            names.append(name)
            let sensitive = catalog.isSensitive(name: name)
            let pos: Position? = r.meta.coord.map { sensitive ? Position.coarsen(lat: $0.latitude, lon: $0.longitude) : Position(lat: $0.latitude, lon: $0.longitude, acc: 15, coarse: false) } ?? drive.lastFix.map { Position.from($0, sensitive: sensitive) }
            let s = Sighting(name: name, key: key, t: r.meta.date ?? .now, n: n, position: pos, thumb: nil, src: "photo"); context.insert(s); ids.append(s.id)
        }
        if let jpeg = r.image.jpegData(compressionQuality: 0.88) {
            let sensitive = names.contains { catalog.isSensitive(name: $0) }
            let pos: Position? = r.meta.coord.map { sensitive ? Position.coarsen(lat: $0.latitude, lon: $0.longitude) : Position(lat: $0.latitude, lon: $0.longitude, acc: 15, coarse: false) }
            context.insert(PhotoItem(t: r.meta.date ?? .now, kind: "photo", species: names, dets: r.dets, image: jpeg, thumb: r.image.preparingThumbnail(of: CGSize(width: 160, height: 160))?.jpegData(compressionQuality: 0.7), width: Int(r.image.size.width * r.image.scale), height: Int(r.image.size.height * r.image.scale), position: pos, sightingIds: ids))
        }
        try? context.save(); dismiss()
    }
}

extension UIImage.Orientation { var exifValue: Int { switch self { case .up: 1; case .down: 3; case .left: 8; case .right: 6; case .upMirrored: 2; case .downMirrored: 4; case .leftMirrored: 5; case .rightMirrored: 7; @unknown default: 1 } } }
