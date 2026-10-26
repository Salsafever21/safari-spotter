import SwiftUI
import SwiftData

@main
struct SafariSpotterApp: App {
    // SwiftData-Container für Sichtungen, Fotos, Korrekturen und Game Drives
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self)
        } catch {
            fatalError("SwiftData konnte nicht gestartet werden: \(error)")
        }
    }()

    @StateObject private var catalog = SpeciesCatalog.shared
    @StateObject private var drive = DriveRecorder.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            LiveView()
                .environmentObject(catalog)
                .environmentObject(drive)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}

/// Einstellungen, 1:1 zur Web-App (ss.settings); gespeichert in UserDefaults
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    @Published var threshold: Double { didSet { d.set(threshold, forKey: "threshold") } }
    @Published var labels: Bool { didSet { d.set(labels, forKey: "labels") } }
    @Published var far: String { didSet { d.set(far, forKey: "far") } }          // off | on (2×2 Kacheln) | max (3×3)
    @Published var region: String { didSet { d.set(region, forKey: "region") } } // auto | none | <key>
    @Published var gps: Bool { didSet { d.set(gps, forKey: "gps") } }
    @Published var collect: Bool { didSet { d.set(collect, forKey: "collect") } }
    @Published var snapshots: Bool { didSet { d.set(snapshots, forKey: "snapshots") } }
    @Published var autoTrack: Bool { didSet { d.set(autoTrack, forKey: "autoTrack") } }
    @Published var res: String { didSet { d.set(res, forKey: "res") } }          // 720 | 1080 | 2160
    private init() {
        threshold = d.object(forKey: "threshold") as? Double ?? 0.4
        labels = d.object(forKey: "labels") as? Bool ?? true
        far = d.string(forKey: "far") ?? "on"
        region = d.string(forKey: "region") ?? "auto"
        gps = d.object(forKey: "gps") as? Bool ?? true
        collect = d.object(forKey: "collect") as? Bool ?? true
        snapshots = d.object(forKey: "snapshots") as? Bool ?? true
        autoTrack = d.object(forKey: "autoTrack") as? Bool ?? false
        res = d.string(forKey: "res") ?? "2160"
    }
}
