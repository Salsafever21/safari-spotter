import UIKit

/// Hintergrundzeit, damit eine Videoaufnahme beim Wechsel in den Hintergrund noch fertig geschrieben wird.
/// `end()` darf mehrfach aufgerufen werden (Fertigstellung und Ablauf der Frist).
final class BackgroundTask {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid

    /// Auf dem Hauptthread aufrufen
    static func begin(_ name: String) -> BackgroundTask {
        let task = BackgroundTask()
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak task] in task?.end() }
        task.lock.lock(); task.id = id; task.lock.unlock()
        return task
    }

    func end() {
        lock.lock(); let current = id; id = .invalid; lock.unlock()
        guard current != .invalid else { return }
        if Thread.isMainThread { UIApplication.shared.endBackgroundTask(current) }
        else { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(current) } }
    }
}
