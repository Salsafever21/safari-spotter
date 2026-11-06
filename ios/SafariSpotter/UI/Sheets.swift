import SwiftUI
import SwiftData
import PhotosUI
import CoreImage
import MapKit
import Combine

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
            let store = SightingStore(context: context, catalog: catalog)
            if let sid = target.sightingId {
                do {
                    guard let s = try store.sighting(id: sid) else {
                        camera.lastError = "Die Sichtung ist nicht mehr vorhanden."
                        return
                    }
                    // Korrektur aus der Liste: ganze Sichtung; bei Nashorn werden auch die verknüpften Fotos ungenau
                    if isNone { try store.remove(s) } else { try store.rename(s, to: name, key: key) }
                    camera.noteSightingChanged(sid)
                } catch {
                    camera.lastError = "Korrektur konnte nicht gespeichert werden: \(error.localizedDescription)"
                    return
                }
            } else if let tid = target.trackId {
                // Live-Rahmen: der CameraController benennt die schon geloggte Sichtung um (oder spaltet ab), statt eine zweite anzulegen
                camera.correct(trackId: tid, name: name, key: key, isNone: isNone, isOther: isOther)
            } else if !isNone {
                guard camera.log(name: name, key: key, thumb: nil, src: "manual", image: nil, size: .zero, noMerge: true) != nil else { return }
            }
            if let img = target.thumb, let predicted = target.predicted {
                let correction = Correction(image: img, predicted: predicted, predKey: catalog.cls(name: predicted)?.key,
                                            conf: nil, label: name, labelKey: key,
                                            status: predicted == name ? "confirmed" : "corrected", region: drive.autoRegion?.key)
                context.insert(correction)
                do { try context.save() }
                catch {
                    context.delete(correction)
                    camera.lastError = "Korrektur konnte nicht gespeichert werden: \(error.localizedDescription)"
                }
            }
        }
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
    @State private var saveError: String?
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
                        guard let d = drive.preparedDrive(sightingsCount: sightings.filter {
                            $0.t >= (drive.startedAt ?? .now)
                        }.reduce(0) { $0 + $1.n }) else { return }
                        context.insert(d)
                        do {
                            try context.save()
                            drive.finishDrive()
                            dismiss()
                        } catch {
                            context.delete(d)
                            saveError = "Game Drive konnte nicht gespeichert werden: \(error.localizedDescription). Die Aufzeichnung läuft weiter."
                        }
                    }
                }
                if let warning = drive.persistenceError { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("Game Drive").navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in tick += 1 }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") {}
            } message: { Text(saveError ?? "") }
        }
    }
    private func big(_ v: String, _ l: String) -> some View { VStack(alignment: .leading) { Text(v).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func tile(_ v: String, _ l: String) -> some View { VStack { Text(v).font(.title3.monospacedDigit().bold()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}

/// Einstellungen
struct SettingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: SpeciesCatalog
    @EnvironmentObject private var drive: DriveRecorder
    @State private var choosingBackup = false
    @State private var backupMessage: String?
    @State private var nativeBackupURL: URL?
    @State private var importedArchives: [URL] = []
    @State private var archiveToDelete: URL?
    @State private var creatingProtectedBackup = false
    @State private var unlockingProtectedBackup = false
    @State private var pendingEncryptedURL: URL?
    @State private var backupBusy = false
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
                Section("Video") {
                    Toggle("Rahmen ins Video einbrennen", isOn: $settings.burnIn).disabled(camera.recording)
                    Text("Videos werden höchstens in Full HD gespeichert. Beim ersten Videostart fragt die App nach dem Mikrofon; ohne Erlaubnis bleibt das Video stumm. Die Datei enthält keinen Standort; in der App und beim Sichern in Fotos gilt nur die 10-km-Zelle. Galerie → Videos zum Ansehen und Teilen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Bisherige Web-App-Daten") {
                    Button("Sicherungsdatei importieren") { choosingBackup = true }
                        .disabled(backupBusy)
                    if pendingEncryptedURL != nil {
                        Button("Passwort erneut eingeben") { unlockingProtectedBackup = true }
                    }
                    if let backupMessage { Text(backupMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("Die Originaldatei bleibt in der App erhalten. Ein erneuter Import legt keine doppelten Einträge an.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !importedArchives.isEmpty {
                        ForEach(importedArchives, id: \.self) { file in
                            HStack {
                                Text("Originalsicherung · \(ByteCountFormatter.string(fromByteCount: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))")
                                    .font(.caption)
                                Spacer()
                                Button("Entfernen", role: .destructive) { archiveToDelete = file }
                            }
                        }
                        Text("Entfernen löscht nur die archivierte Originaldatei. Importierte Sichtungen und Fotos bleiben in der App.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Daten sichern") {
                    Button("Passwortgeschützte Sicherung erstellen") { creatingProtectedBackup = true }
                        .disabled(backupBusy || camera.recordingStarting || camera.recording || camera.recordingFinishing)
                    if camera.recordingStarting || camera.recording || camera.recordingFinishing {
                        Text("Videoaufnahme beenden und speichern lassen, bevor du eine vollständige Sicherung erstellst.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if backupBusy { ProgressView("Sicherung wird verarbeitet …") }
                    if let nativeBackupURL {
                        ShareLink(item: nativeBackupURL) { Label("Sicherungsdatei teilen", systemImage: "square.and.arrow.up") }
                    }
                    Text("Enthält Sichtungen, Fotos, Videos, Korrekturen, Game Drives und Einstellungen. Die Datei lässt sich mit dem Passwort später hier wieder importieren.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Passwort sicher aufbewahren: Ohne Passwort lässt sich diese Sicherung nicht wiederherstellen. Ältere unverschlüsselte Sicherungen bleiben importierbar.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Section { Text("Safari Spotter iOS · Artenmodell v\(catalog.modelVersion) · \(catalog.shownClasses.count) Arten").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Einstellungen")
                .interactiveDismissDisabled(backupBusy)
                .onAppear { importedArchives = WebBackupImporter.archivedFiles() }
                .sheet(isPresented: $creatingProtectedBackup) {
                    BackupPasswordSheet(mode: .create) { password in createProtectedBackup(password) }
                }
                .sheet(isPresented: $unlockingProtectedBackup) {
                    BackupPasswordSheet(mode: .unlock) { password in restoreProtectedBackup(password) }
                }
                .confirmationDialog("Archivierte Originaldatei entfernen?", isPresented: Binding(
                    get: { archiveToDelete != nil }, set: { if !$0 { archiveToDelete = nil } })) {
                    Button("Originaldatei entfernen", role: .destructive) {
                        if let file = archiveToDelete {
                            do { try WebBackupImporter.deleteArchivedFile(file); importedArchives = WebBackupImporter.archivedFiles() }
                            catch { backupMessage = error.localizedDescription }
                        }
                        archiveToDelete = nil
                    }
                } message: { Text("Die importierten Daten bleiben erhalten. Für eine erneute Wiederherstellung dieser Datei muss sie ausserhalb der App vorhanden sein.") }
                .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.item]) { result in
                    switch result {
                    case .failure(let error): backupMessage = "Datei konnte nicht geöffnet werden: \(error.localizedDescription)"
                    case .success(let url):
                        do { try importSelectedBackup(url) }
                        catch { backupMessage = error.localizedDescription }
                    }
                }
        }
    }

    private func createProtectedBackup(_ password: String) {
        guard !camera.recordingStarting, !camera.recording, !camera.recordingFinishing else {
            backupMessage = "Bitte zuerst die Videoaufnahme beenden und speichern lassen."
            return
        }
        backupBusy = true
        if let previous = nativeBackupURL { try? FileManager.default.removeItem(at: previous) }
        nativeBackupURL = nil
        backupMessage = "Sicherung wird erstellt …"
        Task {
            do {
                let raw = try NativeBackupExporter.create(context: context, drive: drive)
                defer { try? FileManager.default.removeItem(at: raw) }
                let protected = try await Task.detached(priority: .userInitiated) {
                    let bundle = try NativeArchive.create(core: raw, clipsDirectory: NativeArchive.clipsDirectory())
                    defer { try? FileManager.default.removeItem(at: bundle) }
                    return try EncryptedBackup.encrypt(bundle, password: password)
                }.value
                nativeBackupURL = protected
                backupMessage = "Verschlüsselte Sicherung bereit. Jetzt über „Sicherungsdatei teilen“ in Dateien sichern."
            } catch { backupMessage = error.localizedDescription }
            backupBusy = false
        }
    }

    private func importSelectedBackup(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if try EncryptedBackup.isEncrypted(url) {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("safari-spotter-import-\(UUID().uuidString).ssbackup")
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: copy.path)
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            if let old = pendingEncryptedURL { try? FileManager.default.removeItem(at: old) }
            pendingEncryptedURL = copy
            backupMessage = "Verschlüsselte Sicherung ausgewählt. Passwort zum Wiederherstellen eingeben."
            unlockingProtectedBackup = true
        } else {
            let report = try WebBackupImporter.perform(url: url, context: context)
            backupMessage = "Importiert: \(report.sightings) Sichtungen, \(report.photos) Fotos, \(report.corrections) Korrekturen und \(report.drives) Fahrten. Original gesichert."
            importedArchives = WebBackupImporter.archivedFiles()
        }
    }

    private func restoreProtectedBackup(_ password: String) {
        guard let encrypted = pendingEncryptedURL else { return }
        backupBusy = true
        backupMessage = "Sicherung wird geprüft und importiert …"
        Task {
            do {
                let decrypted = try await Task.detached(priority: .userInitiated) {
                    try EncryptedBackup.decrypt(encrypted, password: password)
                }.value
                defer { try? FileManager.default.removeItem(at: decrypted) }
                let native = try NativeArchive.isNative(decrypted)
                let extracted = native ? try await Task.detached(priority: .userInitiated) {
                    try NativeArchive.extract(decrypted)
                }.value : nil
                defer { extracted?.removeTemporaryFiles() }
                let clipDirectory = try NativeArchive.clipsDirectory()
                if let extracted { try NativeArchive.checkClipCollisions(extracted, clipsDirectory: clipDirectory) }
                let report = try WebBackupImporter.perform(url: extracted?.core ?? decrypted,
                                                           context: context, archivedSource: encrypted)
                if let extracted {
                    try await Task.detached(priority: .userInitiated) {
                        try NativeArchive.installClips(extracted, clipsDirectory: clipDirectory)
                    }.value
                    ClipLibrary.shared.reload()
                }
                let clipCount = extracted?.clips.filter { $0.pathExtension == "mov" }.count ?? 0
                backupMessage = "Wiederhergestellt: \(report.sightings) Sichtungen, \(report.photos) Fotos, \(report.corrections) Korrekturen, \(report.drives) Fahrten und \(clipCount) Videos."
                importedArchives = WebBackupImporter.archivedFiles()
                try? FileManager.default.removeItem(at: encrypted)
                pendingEncryptedURL = nil
            } catch { backupMessage = error.localizedDescription }
            backupBusy = false
        }
    }
}

private struct BackupPasswordSheet: View {
    enum Mode { case create, unlock }
    let mode: Mode
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Passwort", text: $password)
                    .textContentType(mode == .create ? .newPassword : .password)
                if mode == .create {
                    SecureField("Passwort wiederholen", text: $confirmation)
                        .textContentType(.newPassword)
                    Text("Mindestens 12 Zeichen. Dieses Passwort wird nicht in der App gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(mode == .create ? "Sicherung schützen" : "Sicherung entsperren")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Erstellen" : "Importieren") {
                        onSubmit(password)
                        password = ""; confirmation = ""
                        dismiss()
                    }
                    .disabled(password.isEmpty || (mode == .create && (password.utf8.count < 12 || password != confirmation)))
                }
            }
        }
    }
}

/// Bilder aus der Mediathek analysieren (EXIF-Standort und -Zeit werden übernommen)
struct PhotoAnalysisView: View {
    @ObservedObject var camera: CameraController
    var initialPhoto: PhotoItem? = nil
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
                if initialPhoto == nil {
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) { Label("Bilder auswählen", systemImage: "photo.on.rectangle") }.buttonStyle(.borderedProminent)
                } else { Text("Foto in der Galerie gesichert").font(.caption).foregroundStyle(.secondary) }
                if busy { ProgressView("Analysiere …") }
                if let r = result {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: r.image).resizable().scaledToFit()
                    }
                    List(Array(r.dets.enumerated()), id: \.offset) { _, d in HStack { Text(d.name ?? "Tier").bold(); Spacer(); Text("\(Int(min(d.conf, 0.99) * 100)) %") } }
                    if r.dets.isEmpty {
                        Text("Kein Tier erkannt. Das Foto bleibt in der Galerie.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(r.dets.isEmpty ? "Foto behalten" : "Als Sichtung speichern") { save(r) }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .navigationTitle("Bildanalyse").toolbar { Button("Fertig") { dismiss() } }
            .onChange(of: picked) { Task { await analyze() } }
            .task(id: initialPhoto?.id) { if let initialPhoto { await analyze(data: initialPhoto.image, capturedAt: initialPhoto.t) } }
        }
    }
    private func analyze() async {
        guard let item = picked.first, let data = try? await item.loadTransferable(type: Data.self) else { return }
        await analyze(data: data)
    }
    private func analyze(data: Data, capturedAt: Date? = nil) async {
        guard let ui = UIImage(data: data) else { return }
        busy = true; defer { busy = false }
        // EXIF
        var date: Date? = capturedAt, coord: CLLocationCoordinate2D? = nil
        if capturedAt == nil, let src = CGImageSourceCreateWithData(data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], let lat = g[kCGImagePropertyGPSLatitude] as? Double, let lon = g[kCGImagePropertyGPSLongitude] as? Double {
                coord = CLLocationCoordinate2D(latitude: (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat, longitude: (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon)
            }
            if let e = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = e[kCGImagePropertyExifDateTimeOriginal] as? String { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; date = f.date(from: s) }
        }
        guard let pipeline = try? VisionPipeline(catalog: catalog), let cg = ui.cgImage else { return }
        // Aufrecht und mit Ursprung (0, 0), damit die Ausschnitte in VisionPipeline in App-Koordinaten stimmen
        let ci = VisionPipeline.uprightImage(cg, exifOrientation: Int32(ui.imageOrientation.exifValue))
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
                ?? (initialPhoto == nil ? nil : drive.lastFix.map { Position.from($0, sensitive: sensitive) })
            if let initialPhoto {
                initialPhoto.species = names
                initialPhoto.detsJSON = try? JSONEncoder().encode(r.dets)
                initialPhoto.sightingIds = ids
                initialPhoto.lat = pos?.lat; initialPhoto.lon = pos?.lon; initialPhoto.coarse = pos?.coarse ?? false
            } else {
                context.insert(PhotoItem(t: r.meta.date ?? .now, kind: "photo", species: names, dets: r.dets, image: jpeg, thumb: r.image.preparingThumbnail(of: CGSize(width: 160, height: 160))?.jpegData(compressionQuality: 0.7), width: Int(r.image.size.width * r.image.scale), height: Int(r.image.size.height * r.image.scale), position: pos, sightingIds: ids))
            }
        }
        do { try context.save(); dismiss() }
        catch { camera.lastError = "Bildanalyse konnte nicht gespeichert werden: \(error.localizedDescription)" }
    }
}

extension UIImage.Orientation { var exifValue: Int { switch self { case .up: 1; case .down: 3; case .left: 8; case .right: 6; case .upMirrored: 2; case .downMirrored: 4; case .leftMirrored: 5; case .rightMirrored: 7; @unknown default: 1 } } }
