import Foundation
import CoreLocation
import Combine

/// Punkt der Fahrtspur: [t, lat, lon, speed m/s (-1 unbekannt), alt m]
struct TrackPoint: Codable {
    var t: TimeInterval
    var lat: Double
    var lon: Double
    var spd: Double
    var alt: Double?
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// Statistik eines Game Drives, identisch zu tripStats() im Web
struct DriveStats {
    struct Stop { var t0: Date; var t1: Date; var dur: TimeInterval; var lat: Double; var lon: Double; var open: Bool; var sightings: [Sighting] = [] }
    struct Split { var km: Int; var time: TimeInterval; var at: Date }
    var dist = 0.0, dur: TimeInterval = 0, moving: TimeInterval = 0, standing: TimeInterval = 0
    var stops: [Stop] = [], maxSpeed = 0.0, avgMoving = 0.0, elev = 0.0, splits: [Split] = []

    static let stillSpeed = 0.6       // m/s (~2 km/h)
    static let stopMin: TimeInterval = 45

    static func compute(points: [TrackPoint], startedAt: Date, endedAt: Date?, dist: Double, sightings: [Sighting]) -> DriveStats {
        var st = DriveStats(); st.dist = dist
        let endT = endedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        st.dur = max(0, endT - startedAt.timeIntervalSince1970)
        var stillSince: TimeInterval? = nil, stillLat = 0.0, stillLon = 0.0, refAlt: Double? = nil, acc = 0.0, nextSplit = 1000.0, splitStart = startedAt.timeIntervalSince1970
        for i in 1..<max(1, points.count) {
            let a = points[i - 1], b = points[i]
            let dt = b.t - a.t; if dt <= 0 { continue }
            let d = CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
            let v = d / dt
            // GPS-Tempo bevorzugen, ausser der Ort ändert sich über längere Zeit nicht
            let speed = (b.spd >= 0 && !(d < 5 && dt > 10)) ? b.spd : v
            if speed < stillSpeed {
                st.standing += dt
                if stillSince == nil { stillSince = a.t; stillLat = a.lat; stillLon = a.lon }
            } else {
                st.moving += dt
                if let s = stillSince { if a.t - s >= stopMin { st.stops.append(Stop(t0: Date(timeIntervalSince1970: s), t1: Date(timeIntervalSince1970: a.t), dur: a.t - s, lat: stillLat, lon: stillLon, open: false)) }; stillSince = nil }
                if dt >= 3 && v < 45 { st.maxSpeed = max(st.maxSpeed, v) }
            }
            if d < 2000 { acc += d; if acc >= nextSplit { st.splits.append(Split(km: Int(nextSplit / 1000), time: b.t - splitStart, at: Date(timeIntervalSince1970: b.t))); splitStart = b.t; nextSplit += 1000 } }
            if let alt = b.alt { if let r = refAlt { if alt - r >= 5 { st.elev += alt - r; refAlt = alt } else if r - alt >= 5 { refAlt = alt } } else { refAlt = alt } }
        }
        if let s = stillSince, endT - s >= stopMin { st.stops.append(Stop(t0: Date(timeIntervalSince1970: s), t1: Date(timeIntervalSince1970: endT), dur: endT - s, lat: stillLat, lon: stillLon, open: endedAt == nil)) }
        st.avgMoving = st.moving > 30 ? st.dist / st.moving : 0
        let inDrive = sightings.filter { $0.t >= startedAt && $0.t.timeIntervalSince1970 <= endT }
        for i in st.stops.indices { let s = st.stops[i]; st.stops[i].sightings = inDrive.filter { $0.t >= s.t0.addingTimeInterval(-60) && $0.t <= s.t1.addingTimeInterval(60) } }
        return st
    }
}

/// GPS, Region und Game-Drive-Aufzeichnung. Läuft dank UIBackgroundModes=location auch bei gesperrtem Gerät weiter (Strava-artig).
final class DriveRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = DriveRecorder()
    @Published var lastFix: CLLocation?
    @Published var autoRegion: Region?
    @Published var active = false
    @Published var startedAt: Date?
    @Published var points: [TrackPoint] = []
    @Published var dist = 0.0
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var persistenceError: String?

    private let manager = CLLocationManager()
    private let catalog = SpeciesCatalog.shared
    private let stateURL: URL

    override init() {
        stateURL = DriveRecorder.defaultStateURL
        super.init()
        configure()
    }

    init(stateURL: URL) {
        self.stateURL = stateURL
        super.init()
        configure()
    }

    private func configure() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        restore()
    }

    func start() {
        guard AppSettings.shared.gps else { stop(); return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }
    func stop() {
        manager.stopUpdatingLocation()
        lastFix = nil
        autoRegion = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authorization = m.authorizationStatus
        guard AppSettings.shared.gps else { stop(); return }
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways { m.startUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard AppSettings.shared.gps else { return }
        let valid = locations.filter { $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate) }
            .sorted { $0.timestamp < $1.timestamp }
        guard let newest = valid.last else { return }
        if active {
            let previousTime = points.last?.t
            for loc in valid { addPoint(loc) }
            if points.last?.t != previousTime { persist() }
        }
        if let lastFix, newest.timestamp < lastFix.timestamp { return }
        lastFix = newest
        let region = catalog.region(for: newest.coordinate)
        if region?.key != autoRegion?.key { autoRegion = region }
    }

    /// Region für das Vorwissen (Einstellung "auto" | "none" | key)
    func currentRegion(setting: String) -> Region? {
        if setting == "none" { return nil }
        if setting == "auto" { return AppSettings.shared.gps ? autoRegion : nil }
        return catalog.regions.first { $0.key == setting }
    }

    func currentPosition(sensitive: Bool) -> Position? {
        guard AppSettings.shared.gps, let lastFix,
              abs(Date().timeIntervalSince(lastFix.timestamp)) < 180 else { return nil }
        return Position.from(lastFix, sensitive: sensitive)
    }

    // MARK: Game Drive

    func startDrive() {
        AppSettings.shared.gps = true
        active = true; startedAt = .now; points = []; dist = 0
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        start(); persist()
    }

    /// Erst einen Datensatz vorbereiten; die laufende Route bleibt erhalten, bis SwiftData ihn bestätigt hat.
    func preparedDrive(sightingsCount: Int) throws -> Drive? {
        guard active, let s = startedAt else { return nil }
        return try Drive(startedAt: s, endedAt: .now, dist: dist, points: points, sightings: sightingsCount)
    }

    /// Ein erfolgreich gespeicherter Drive gewinnt gegen eine veraltete aktive JSON-Datei.
    /// Das kann nach einem Fehler beim letzten atomaren Schreiben auftreten.
    func reconcileCompletedDrive(startedAt completedStart: Date) {
        guard active, let start = startedAt,
              abs(start.timeIntervalSince(completedStart)) < 0.001 else { return }
        finishDrive()
    }

    func finishDrive() {
        guard active else { return }
        active = false; startedAt = nil; points = []; dist = 0
        manager.allowsBackgroundLocationUpdates = false
        persist()
    }

    /// Sichert auch die letzten GPS-Punkte, bevor iOS die App im Hintergrund anhält.
    func checkpoint() { if active { persist() } }

    private func addPoint(_ loc: CLLocation) {
        let t = loc.timestamp.timeIntervalSince1970
        guard let startedAt, t >= startedAt.timeIntervalSince1970,
              points.last.map({ t > $0.t }) ?? true else { return }
        if let last = points.last {
            let d = CLLocation(latitude: last.lat, longitude: last.lon).distance(from: loc)
            if d < 10 && t - last.t < 15 { return }
            if loc.horizontalAccuracy <= 60 && d >= 10 && d < 2000 { dist += d }
        }
        points.append(TrackPoint(t: t, lat: (loc.coordinate.latitude * 1e5).rounded() / 1e5, lon: (loc.coordinate.longitude * 1e5).rounded() / 1e5,
                                 spd: loc.speed >= 0 ? (loc.speed * 10).rounded() / 10 : -1, alt: loc.verticalAccuracy >= 0 ? loc.altitude.rounded() : nil))
        if points.count > 20000 { points.removeFirst(points.count - 20000) }
    }

    func stats(sightings: [Sighting]) -> DriveStats? {
        guard active, let s = startedAt else { return nil }
        return DriveStats.compute(points: points, startedAt: s, endedAt: nil, dist: dist, sightings: sightings)
    }

    // Laufender Drive übersteht einen App-Neustart (ss.trip)
    private static var defaultStateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("drive-state.json")
    }
    private struct State: Codable { var active: Bool; var startedAt: Date?; var points: [TrackPoint]; var dist: Double }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(State(active: active, startedAt: startedAt, points: points, dist: dist))
                .write(to: stateURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Game Drive konnte nicht zwischengespeichert werden: \(error.localizedDescription)"
        }
    }
    private func restore() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let s = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard s.active else { return }
            guard let startDate = s.startedAt else { throw CocoaError(.fileReadCorruptFile) }
            active = true; startedAt = startDate; points = s.points; dist = s.dist
            manager.allowsBackgroundLocationUpdates = true
            start()
        } catch {
            persistenceError = "Letzter Game Drive konnte nicht wiederhergestellt werden: \(error.localizedDescription)"
        }
    }
}
