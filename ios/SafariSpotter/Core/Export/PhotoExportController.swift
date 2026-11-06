import Foundation
import SwiftData
import Combine

/// Ein Auftrag für die ganze App. Ansichtswechsel starten keinen zweiten Export; Wiederholen überspringt Erfolge.
@MainActor
final class PhotoExportController: ObservableObject {
    static let shared = PhotoExportController()
    typealias Writer = @MainActor (PhotoItem, [TimeInterval], SpeciesCatalog) async throws -> Void

    @Published private(set) var isRunning = false
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    @Published private(set) var currentID: UUID?
    @Published private(set) var savedIDs: Set<UUID> = []
    @Published private(set) var lastError: String?
    @Published private var retryBlocked = false
    private var remaining: [UUID] = []
    private var context: ModelContext?
    private var catalog: SpeciesCatalog?
    private var task: Task<Void, Never>?
    private let writer: Writer

    var hasPendingJob: Bool { !isRunning && !remaining.isEmpty && lastError != nil }
    var canRetry: Bool { hasPendingJob && !retryBlocked }
    var canStart: Bool { !isRunning && !hasPendingJob }
    var remainingCount: Int { remaining.count }

    init(writer: @escaping Writer = { photo, times, catalog in
        try await PhotoExporter.export(photo, isSensitive: catalog.isSensitive, protectedTimes: times)
    }) { self.writer = writer }

    @discardableResult
    func start(photos: [PhotoItem], context: ModelContext, catalog: SpeciesCatalog) -> Bool {
        guard canStart else { return false }
        var seen: Set<UUID> = []
        let ids = photos.map(\.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return false }
        self.context = context; self.catalog = catalog
        remaining = ids; total = ids.count; completed = 0; savedIDs = []
        return launch()
    }

    @discardableResult
    func retry() -> Bool {
        guard canRetry else { return false }
        return launch()
    }

    /// Nur den fehlgeschlagenen Auftrag beenden, niemals Originalfotos oder gesicherte Mediathek-Kopien entfernen.
    @discardableResult
    func discardFailedJob() -> Bool {
        guard hasPendingJob else { return false }
        remaining = []; context = nil; catalog = nil; task = nil
        total = 0; completed = 0; savedIDs = []; lastError = nil; retryBlocked = false
        return true
    }

    private func launch() -> Bool {
        guard let context, let catalog, !remaining.isEmpty else { return false }
        // Synchron vor dem Task setzen: auch zwei schnelle Taps können nicht parallel starten.
        isRunning = true; lastError = nil; retryBlocked = false
        task = Task {
            defer { isRunning = false; currentID = nil }
            do {
                let protectedTimes = try Exporters.protectedTimes(context: context, catalog: catalog)
                while let id = remaining.first {
                    currentID = id
                    // Nach einer fehlgeschlagenen Runde kann ein Foto inzwischen gelöscht worden sein.
                    guard let photo = try context.fetch(FetchDescriptor<PhotoItem>(predicate: #Predicate { $0.id == id })).first else {
                        throw ExportError.missingPhoto
                    }
                    try await writer(photo, protectedTimes, catalog)
                    savedIDs.insert(id); completed += 1; remaining.removeFirst()
                }
                self.context = nil; self.catalog = nil
            } catch {
                // Ein gelöschtes oder nicht kodierbares Foto wird durch erneutes Tippen nicht wiederhergestellt.
                if error is ExportError { retryBlocked = true }
                if case .metadata? = error as? PhotoExporter.ExportError { retryBlocked = true }
                lastError = "\(completed) von \(total) Fotos gesichert. \(error.localizedDescription)"
            }
        }
        return true
    }

    /// Auch im Test wird auf denselben tatsächlichen Auftrag gewartet, ohne Zeitannahmen oder zweite Ausführung.
    func waitUntilIdle() async { await task?.value }

    enum ExportError: LocalizedError {
        case missingPhoto
        var errorDescription: String? { "Ein noch offenes Foto ist nicht mehr in der App vorhanden. Beende diesen Exportauftrag, bevor du eine neue Auswahl sicherst." }
    }
}
