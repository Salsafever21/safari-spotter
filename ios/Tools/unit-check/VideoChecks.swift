import Foundation
// Prüfungen für die Videoaufnahme ohne iOS-SDK: Clip-Dateiformat und Ablage (Schnittstelle für Backup/Restore),
// Ausgabegrösse und Overlay-Geometrie, Timer, und die Bildverteilung, die Aufnahme und Erkennung trennt.

/// Simuliert die Kamera: `frames` Bilder im Abstand `frameGap`, verteilt über `DetectionGate.route` wie in
/// `CameraController.captureOutput`; jede Erkennung braucht `detectionTime`. Liefert (aufgenommen, erkannt, max. gleichzeitig).
func routeUnderSlowDetection(frames: Int, frameGap: TimeInterval, detectionTime: TimeInterval) -> (Int, Int, Int) {
    let gate = DetectionGate(); gate.setWanted(true)
    let detectQueue = DispatchQueue(label: "test.detect")
    let stats = NSLock()
    var recorded = 0, detected = 0, running = 0, maxRunning = 0
    for _ in 0..<frames {
        gate.route(record: { stats.lock(); recorded += 1; stats.unlock() }, detectOn: detectQueue) {
            stats.lock(); running += 1; maxRunning = max(maxRunning, running); detected += 1; stats.unlock()
            Thread.sleep(forTimeInterval: detectionTime)
            stats.lock(); running -= 1; stats.unlock()
        }
        Thread.sleep(forTimeInterval: frameGap)
    }
    detectQueue.sync {}
    stats.lock(); defer { stats.unlock() }
    return (recorded, detected, maxRunning)
}

func runVideoChecks() async {
    // MARK: Ausgabegrösse und Geometrie
    expect(VideoGeometry.outputSize(for: CGSize(width: 2160, height: 3840)) == CGSize(width: 1080, height: 1920), "4K-Hochformat → Full HD")
    expect(VideoGeometry.outputSize(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 1080, height: 1920), "Full HD bleibt")
    expect(VideoGeometry.outputSize(for: CGSize(width: 720, height: 1280)) == CGSize(width: 720, height: 1280), "720p bleibt (nie hochskaliert)")
    expect(VideoGeometry.outputSize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080), "4K-Querformat → Full HD")
    let odd = VideoGeometry.outputSize(for: CGSize(width: 1081, height: 1921))
    expect(Int(odd.width) % 2 == 0 && Int(odd.height) % 2 == 0, "gerade Pixelzahlen für den Encoder")
    expect(VideoGeometry.outputSize(for: .zero) == .zero, "ohne Bild keine Grösse")
    expect(near(VideoGeometry.scale(CGRect(x: 216, y: 384, width: 432, height: 768), from: CGSize(width: 2160, height: 3840), to: CGSize(width: 1080, height: 1920)),
                CGRect(x: 108, y: 192, width: 216, height: 384)), "Rahmen von 4K auf Full HD")
    expect(near(VideoGeometry.pointScale(output: CGSize(width: 1080, height: 1920)), 1080 / 393, 1e-9), "Linien wie auf einem 393-pt-iPhone")
    let out = CGSize(width: 1080, height: 1920), label = CGSize(width: 200, height: 40)
    expect(VideoGeometry.labelOrigin(box: CGRect(x: 100, y: 300, width: 300, height: 300), label: label, in: out, gap: 4) == CGPoint(x: 100, y: 256), "Plakette über dem Rahmen")
    expect(VideoGeometry.labelOrigin(box: CGRect(x: 100, y: 10, width: 300, height: 300), label: label, in: out, gap: 4) == CGPoint(x: 100, y: 14), "kein Platz oben: innen oben")
    expect(VideoGeometry.labelOrigin(box: CGRect(x: 1000, y: 300, width: 80, height: 80), label: label, in: out, gap: 4).x == 880, "am rechten Rand ganz im Bild")
    expect(abs(VideoGeometry.bitrate(for: out, hevc: true) - 9_953_280) < 2, "HEVC-Bitrate Full HD ≈ 10 Mbit/s")
    expect(abs(VideoGeometry.bitrate(for: out, hevc: false) - 15_552_000) < 2, "H.264-Bitrate Full HD ≈ 15,6 Mbit/s")
    expect(VideoGeometry.timerText(0) == "00:00" && VideoGeometry.timerText(42.9) == "00:42" && VideoGeometry.timerText(725) == "12:05", "Timer unter einer Stunde")
    expect(VideoGeometry.timerText(3723) == "1:02:03" && VideoGeometry.timerText(-3) == "00:00", "Timer ab einer Stunde, nie negativ")
    let c0 = TrackPalette.rgb(0), c9 = TrackPalette.rgb(9), cm = TrackPalette.rgb(-1)
    expect(near(CGFloat(c0.r), 240 / 255) && near(CGFloat(c0.g), 169 / 255) && near(CGFloat(c0.b), 58 / 255), "erste Rahmenfarbe wie im Web")
    expect(c9 == TrackPalette.rgb(1) && cm == TrackPalette.rgb(7), "Farbindex läuft ringförmig")

    // MARK: Tor zwischen Bildlieferung und Erkennung
    let gate = DetectionGate()
    expect(!gate.tryBegin(), "ausgeschaltet: kein Bild in die Erkennung")
    gate.setWanted(true)
    expect(gate.tryBegin() && !gate.tryBegin(), "eingeschaltet: genau ein Bild, solange es bearbeitet wird")
    gate.end()
    expect(gate.tryBegin(), "nach dem Ende wieder frei"); gate.end()
    gate.setWanted(false)
    expect(!gate.tryBegin(), "wieder ausgeschaltet")

    // Echte Zeit: 120 Bilder im Abstand von 3 ms, jede Erkennung dauert 25 ms (also ~8× langsamer als die Bildfolge).
    // Jedes Bild muss bei der Aufnahme ankommen, die Erkennung darf nie doppelt laufen und nie Bilder anstauen.
    let (recorded, detected, maxRunning) = routeUnderSlowDetection(frames: 120, frameGap: 0.003, detectionTime: 0.025)
    expect(recorded == 120, "alle 120 Bilder bei der Aufnahme, trotz langsamer Erkennung (\(recorded))")
    expect(maxRunning == 1, "nie zwei Erkennungen gleichzeitig (\(maxRunning))")
    expect(detected > 0 && detected < 40, "Erkennung nimmt nur freie Bilder, staut nichts an (\(detected) von 120)")

    // MARK: Clip-Dateien (Schnittstelle für Backup/Restore)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipcheck-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let coarseCell = Position.coarsen(lat: -24.98765, lon: 31.54321)
    let a = UUID(), b = UUID()
    var ra = ClipRecord(id: a, createdAt: Date(timeIntervalSince1970: 1_793_000_000), duration: 12.5, width: 1080, height: 1920, codec: "hvc1",
                        fileSize: 5, frames: 375, droppedFrames: 0, burnedIn: true, trackingActive: true, species: ["Elefant"],
                        sightingIds: [UUID()], sensitive: false, lat: coarseCell.lat, lon: coarseCell.lon, coarse: true, lens: "Weitwinkel",
                        state: .complete, thumbnail: ClipFiles.thumbnailName(a))
    expect(ra.file == "\(a.uuidString).mov", "Dateiname der Videodatei ist <id>.mov")
    try? Data("12345".utf8).write(to: ClipFiles.movieURL(a, in: dir))
    try? Data([0xff, 0xd8]).write(to: ClipFiles.thumbnailURL(a, in: dir))
    expect((try? ClipFiles.save(ra, in: dir)) != nil, "Metadaten speichern")
    expect(ClipFiles.load(a, in: dir) == ra, "Metadaten verlustfrei zurückgelesen")
    let json = (try? String(contentsOf: ClipFiles.metadataURL(a, in: dir), encoding: .utf8)) ?? ""
    for key in ["\"version\"", "\"id\"", "\"createdAt\"", "\"duration\"", "\"width\"", "\"height\"", "\"codec\"", "\"fileSize\"", "\"frames\"",
                "\"droppedFrames\"", "\"burnedIn\"", "\"trackingActive\"", "\"species\"", "\"sightingIds\"", "\"sensitive\"", "\"lat\"", "\"lon\"",
                "\"coarse\"", "\"lens\"", "\"state\"", "\"file\"", "\"thumbnail\""] {
        expect(json.contains(key), "JSON enthält \(key)")
    }
    expect(json.contains("\"createdAt\" : \"2026-") && json.contains("\"state\" : \"complete\""), "ISO-8601-Datum und Zustand als Text")

    // Unverbindlich gegen die dokumentierte Schnittstelle: ein von Hand geschriebenes Dokument wird gelesen
    let documented = """
    {"version":1,"id":"\(b.uuidString)","createdAt":"2026-11-05T14:03:00Z","duration":3.0,"width":1080,"height":1920,"codec":"avc1",
     "fileSize":0,"frames":90,"droppedFrames":0,"burnedIn":false,"trackingActive":false,"species":[],"sightingIds":[],
     "sensitive":false,"coarse":false,"state":"recording","file":"\(b.uuidString).mov"}
    """
    try? Data(documented.utf8).write(to: ClipFiles.metadataURL(b, in: dir))
    try? Data("xx".utf8).write(to: ClipFiles.movieURL(b, in: dir))
    expect(ClipFiles.load(b, in: dir)?.state == .recording && ClipFiles.load(b, in: dir)?.lat == nil, "dokumentiertes JSON (ohne Standort, ohne Vorschaubild) lesbar")
    try? Data("kaputt".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
    let listed = (try? ClipFiles.list(in: dir)) ?? []
    expect(listed.map(\.id) == [b, a], "Liste: neueste zuerst, unlesbare JSON übersprungen")

    // Wiederherstellung nach Abbruch: b lief noch → abspielbar geprüft; Waise c ohne JSON → beschädigt; laufender Clip d unberührt
    let c = UUID(), d = UUID()
    try? Data("yy".utf8).write(to: ClipFiles.movieURL(c, in: dir))
    var rd = ClipRecord(id: d, createdAt: Date(), burnedIn: false, trackingActive: false, state: .recording)
    rd.fileSize = 0
    try? ClipFiles.save(rd, in: dir)
    expect((try? ClipFiles.orphanMovies(in: dir)) == [c], "Video ohne Metadaten gefunden")
    let changed = await ClipFiles.recoverInterrupted(in: dir, excluding: d) { url in
        url.lastPathComponent.hasPrefix(b.uuidString) ? ClipProbe(duration: 3.0, width: 1080, height: 1920) : nil
    }
    expect(Set(changed.changed.map(\.id)) == [b, c], "nur abgebrochene Clips geprüft, laufender ausgenommen")
    expect(changed.failedIDs.isEmpty, "Wiederherstellung ohne Schreibfehler")
    expect(ClipFiles.load(b, in: dir)?.state == .recovered && ClipFiles.load(b, in: dir)?.duration == 3.0, "lesbarer Abbruch → wiederhergestellt")
    expect(ClipFiles.load(c, in: dir)?.state == .damaged && FileManager.default.fileExists(atPath: ClipFiles.movieURL(c, in: dir).path), "unlesbar → beschädigt, Datei bleibt")
    expect(ClipFiles.load(d, in: dir)?.state == .recording, "laufende Aufnahme unverändert")
    expect(ClipFiles.load(a, in: dir)?.state == .complete, "abgeschlossene Clips unverändert")

    // Restore: idempotent, prüft Grösse, setzt nie eine genaue Position
    let restoreDir = dir.appendingPathComponent("restore", isDirectory: true)
    let installed = try? ClipFiles.install(movie: ClipFiles.movieURL(a, in: dir), record: ra, thumbnail: Data([0xff, 0xd8]), in: restoreDir)
    expect(installed?.fileSize == 5 && installed?.thumbnail == ClipFiles.thumbnailName(a), "Restore kopiert Video und Vorschaubild")
    expect(FileManager.default.fileExists(atPath: ClipFiles.movieURL(a, in: restoreDir).path), "Video im Zielordner")
    ra.duration = 99
    expect((try? ClipFiles.install(movie: ClipFiles.movieURL(a, in: dir), record: ra, thumbnail: nil, in: restoreDir))?.duration == 12.5, "zweiter Restore ändert nichts")
    var wrongSize = ClipRecord(id: UUID(), createdAt: Date(), fileSize: 999, burnedIn: false, trackingActive: false, state: .complete)
    do { _ = try ClipFiles.install(movie: ClipFiles.movieURL(a, in: dir), record: wrongSize, thumbnail: nil, in: restoreDir); expect(false, "falsche Grösse muss scheitern") }
    catch { expect((error as? ClipFileError) == .sizeMismatch(expected: 999, actual: 5), "falsche Grösse erkannt") }
    wrongSize.fileSize = 0; wrongSize.lat = -24.98765; wrongSize.lon = 31.54321; wrongSize.coarse = false
    do { _ = try ClipFiles.install(movie: ClipFiles.movieURL(a, in: dir), record: wrongSize, thumbnail: nil, in: restoreDir); expect(false, "genaue Position muss scheitern") }
    catch { expect((error as? ClipFileError) == .invalidRecord("Standort nicht vergröbert"), "genaue Position abgelehnt (Artenschutz)") }

    // Löschen entfernt alle drei Dateien, nichts sonst
    expect((try? ClipFiles.delete(a, in: dir)) != nil, "löschen")
    expect(!FileManager.default.fileExists(atPath: ClipFiles.movieURL(a, in: dir).path) && !FileManager.default.fileExists(atPath: ClipFiles.metadataURL(a, in: dir).path)
           && !FileManager.default.fileExists(atPath: ClipFiles.thumbnailURL(a, in: dir).path), "Video, Metadaten, Vorschaubild weg")
    expect(ClipFiles.load(b, in: dir) != nil, "andere Clips bleiben")

    // Speicherplatz
    expect(ClipFiles.hasRoom(available: nil, minimum: ClipFiles.minimumFreeToStart), "unbekannter Speicher blockiert nicht")
    expect(!ClipFiles.hasRoom(available: 900_000_000, minimum: ClipFiles.minimumFreeToStart) && ClipFiles.hasRoom(available: 900_000_000, minimum: ClipFiles.minimumFreeWhileRecording),
           "Start ab 1 GB, laufende Aufnahme bis 300 MB")
}
