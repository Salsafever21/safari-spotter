import Foundation
import CoreGraphics

/// Ein verfolgtes Tier, wie `tracks[]` in der Web-App
final class Track: Identifiable {
    let id: Int
    var box: CGRect
    var cls: String
    var score: Double
    var firm: Bool
    var verified = false
    var locked = false
    var collected = false
    var clsRuns = 0
    var hits = 1
    var missed = 0
    let born: TimeInterval
    var lastCls: TimeInterval = 0
    var probs: [Double]? = nil
    var decision = SpeciesDecision(name: nil, key: nil, confidence: 0, sure: false, other: false)
    var logged = false
    var sightingId: UUID? = nil
    var pendingSpecies: [String: Double]? = nil   // YOLO-Pfad: Artwahrscheinlichkeiten der letzten Detektion
    let colorIndex: Int

    init(id: Int, det: Detection, now: TimeInterval) {
        self.id = id; box = det.box; cls = det.cls; score = det.score; firm = det.firm; born = now; colorIndex = (id - 1) % 8
        pendingSpecies = det.species
    }
    var isShown: Bool { hits >= 2 && (firm || verified) }
    var displayName: String {
        if let n = decision.name { return decision.sure || decision.other ? n : n + "?" }
        return Tracker.cocoFallback[cls] ?? "Tier"
    }
}

/// IoU-Tracker mit Glättung, Bestätigung schwacher Kandidaten und Artglättung (0.6/0.4), 1:1 zur Web-App
final class Tracker {
    static let cocoFallback: [String: String] = ["bird": "Vogel", "cat": "Raubkatze?", "dog": "Hundeartiges?", "horse": "Antilope / Zebra?", "sheep": "Antilope?", "cow": "Antilope / Büffel?", "elephant": "Elefant", "bear": "Grosses Tier?", "zebra": "Zebra", "giraffe": "Giraffe"]
    private(set) var tracks: [Track] = []
    private var nextId = 1

    func reset() { tracks = []; }

    func update(with detsIn: [Detection], visible: CGRect, now: TimeInterval) {
        // Höchstens drei schwache Kandidaten, sinnvoll gross
        let minSide = min(visible.width, visible.height) * 0.03, maxSide = max(visible.width, visible.height) * 0.9
        var weak = 0
        let dets = detsIn.filter { d in
            if d.firm { return true }
            if d.box.width < minSide || d.box.height < minSide || d.box.width > maxSide || d.box.height > maxSide { return false }
            weak += 1; return weak <= 3
        }
        var used = Set<Int>()
        tracks.sort { $0.hits > $1.hits }
        for t in tracks {
            var best = -1, bestIou = 0.25
            for (i, d) in dets.enumerated() where !used.contains(i) {
                let v = VisionPipeline.iou(t.box, d.box); if v > bestIou { bestIou = v; best = i }
            }
            if best >= 0 {
                used.insert(best); let d = dets[best]; let a: CGFloat = 0.55
                t.box = CGRect(x: t.box.minX * (1 - a) + d.box.minX * a, y: t.box.minY * (1 - a) + d.box.minY * a,
                               width: t.box.width * (1 - a) + d.box.width * a, height: t.box.height * (1 - a) + d.box.height * a)
                if d.firm || !t.firm { t.cls = d.cls; t.score = d.score }
                if d.firm { t.firm = true }
                if let s = d.species { t.pendingSpecies = s }
                t.hits += 1; t.missed = 0
            } else { t.missed += 1 }
        }
        for (i, d) in dets.enumerated() where !used.contains(i) {
            tracks.append(Track(id: nextId, det: d, now: now)); nextId += 1
        }
        tracks.removeAll { t in
            if t.missed > 10 || (t.hits < 2 && t.missed > 2) { return true }
            if !t.firm && !t.verified && (t.clsRuns >= 2 || (t.clsRuns >= 1 && now - t.born > 2.5)) { return true }
            return false
        }
    }

    /// Nächster Track, der eine Artbestimmung braucht (schwache zuerst)
    func candidateForClassification(now: TimeInterval) -> Track? {
        tracks.filter { !$0.locked && $0.missed == 0 && ($0.hits >= 2 || !$0.firm) && now - $0.lastCls > ($0.decision.name != nil && $0.decision.sure ? 0.9 : 0.3) }
            .sorted { ($0.firm ? 1 : 0, $0.lastCls) < ($1.firm ? 1 : 0, $1.lastCls) }.first
    }

    /// YOLO-Pfad: Artwahrscheinlichkeiten des Detektors einarbeiten (gleiche Glättung wie beim Artenkopf, zählt aber nicht als
    /// Kopf-Durchlauf, damit der Kopf bei schwachen Kandidaten weiterhin seine zweite Meinung abgeben kann). Liefert die geänderten Tracks.
    func applyDetectorSpecies(catalog: SpeciesCatalog, probs: ([String: Double]) -> [Double]) -> [Track] {
        var changed: [Track] = []
        for t in tracks {
            guard let s = t.pendingSpecies else { continue }
            t.pendingSpecies = nil
            if t.locked || t.hits < 2 { continue }
            let p = probs(s)
            if let old = t.probs { t.probs = zip(old, p).map { $0 * 0.6 + $1 * 0.4 } } else { t.probs = p }
            t.decision = SpeciesDecision.decide(t.probs!, catalog: catalog)
            if !t.firm, t.decision.name != nil, !t.decision.other, t.decision.confidence >= 0.6 { t.verified = true }
            changed.append(t)
        }
        return changed
    }

    /// Neue Wahrscheinlichkeiten einarbeiten (geglättet) und entscheiden
    func apply(probs: [Double], to t: Track, catalog: SpeciesCatalog, now: TimeInterval) -> SpeciesDecision {
        t.lastCls = now; t.clsRuns += 1
        if let old = t.probs { t.probs = zip(old, probs).map { $0 * 0.6 + $1 * 0.4 } } else { t.probs = probs }
        let d = SpeciesDecision.decide(t.probs!, catalog: catalog)
        t.decision = d
        if !t.firm, d.name != nil, !d.other, d.confidence >= 0.6 { t.verified = true }
        return d
    }
}
