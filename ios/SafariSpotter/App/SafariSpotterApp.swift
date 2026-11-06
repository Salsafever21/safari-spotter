import SwiftUI
import SwiftData

@main
struct SafariSpotterApp: App {
    // SwiftData-Container für Sichtungen, Fotos, Korrekturen und Game Drives
    @State private var storage = StorageLaunch.open()

    @StateObject private var catalog = SpeciesCatalog.shared
    @StateObject private var drive = DriveRecorder.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            Group {
                switch storage {
                case .ready(let container):
                    Group {
                        if settings.onboardingComplete { LiveView() }
                        else { TravelSetupView(firstLaunch: true) }
                    }
                        .environmentObject(catalog)
                        .environmentObject(drive)
                        .environmentObject(settings)
                        .modelContainer(container)
                case .failed(let message):
                    StorageFailureView(message: message) { storage = StorageLaunch.open() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

private enum StorageLaunch {
    case ready(ModelContainer)
    case failed(String)

    static func open() -> StorageLaunch {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.environment["SAFARI_SPOTTER_UI_FIXTURE"] == "drive-history" {
                return .ready(try DriveHistoryFixture.make())
            }
            #endif
            return .ready(try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self))
        }
        catch { return .failed(error.localizedDescription) }
    }
}

private struct StorageFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
            Text("Gespeicherte Daten können nicht geöffnet werden").font(.headline).multilineTextAlignment(.center)
            Text("Bitte Safari Spotter nicht löschen. Die App entfernt bei diesem Fehler keine Aufnahmen. Prüfe den freien Speicher und versuche es erneut.")
                .multilineTextAlignment(.center)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Erneut versuchen", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(24)
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
    @Published var lensID: String { didSet { d.set(lensID, forKey: "lensID") } }
    @Published var burnIn: Bool { didSet { d.set(burnIn, forKey: "burnIn") } }  // Rahmen ins Video einbrennen (wie settings.burnIn im Web)
    @Published var originCountry: String { didSet { d.set(originCountry, forKey: "originCountry") } }
    @Published var destinationCountry: String { didSet { d.set(destinationCountry, forKey: "destinationCountry") } }
    @Published var onboardingComplete: Bool { didSet { d.set(onboardingComplete, forKey: "onboardingComplete") } }
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
        lensID = d.string(forKey: "lensID") ?? ""
        burnIn = d.object(forKey: "burnIn") as? Bool ?? true
        originCountry = d.string(forKey: "originCountry") ?? ""
        destinationCountry = d.string(forKey: "destinationCountry") ?? ""
        onboardingComplete = d.bool(forKey: "onboardingComplete")
    }
}
