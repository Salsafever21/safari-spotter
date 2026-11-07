import Foundation

/// Trennt die Bildlieferung der Kamera von der langsamen Erkennung: Die Kamera gibt jedes Bild an die Videoaufnahme weiter
/// und reicht der Erkennung nur dann eines, wenn sie gewünscht ist und gerade keines bearbeitet. So staut sich nichts,
/// und die Aufnahme verliert keine Bilder, egal wie lange ein Erkennungsdurchlauf dauert. Thread-sicher.
final class DetectionGate {
    private let lock = NSLock()
    private var wanted = false
    private var inFlight = false

    /// Erkennung ein- oder ausschalten (Tracken)
    func setWanted(_ on: Bool) {
        lock.lock(); wanted = on; lock.unlock()
    }

    var isWanted: Bool { lock.lock(); defer { lock.unlock() }; return wanted }

    /// true, wenn das aktuelle Bild in die Erkennung darf; dann muss genau einmal `end()` folgen
    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard wanted, !inFlight else { return false }
        inFlight = true
        return true
    }

    func end() {
        lock.lock(); inFlight = false; lock.unlock()
    }

    /// Verteilt ein Kamerabild: zuerst immer an die Aufnahme (`record`, muss sofort zurückkehren), danach nur bei freier,
    /// eingeschalteter Erkennung asynchron an `detect` auf `queue`. Die Erkennung kann die Aufnahme so nie aufhalten.
    func route(record: () -> Void, detectOn queue: DispatchQueue, detect: @escaping () -> Void) {
        record()
        guard tryBegin() else { return }
        queue.async {
            defer { self.end() }
            detect()
        }
    }
}
