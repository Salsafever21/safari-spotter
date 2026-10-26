import Foundation
// Liest input.json (Track, Prob-Vektoren, Boxen), rechnet mit der Swift-Logik und schreibt swift-out.json
struct Input: Decodable {
    struct Pt: Decodable { let t: Double; let lat: Double; let lon: Double; let spd: Double; let alt: Double? }
    struct Sgt: Decodable { let t: Double; let name: String }
    struct Box: Decodable { let x: Double; let y: Double; let w: Double; let h: Double; let cls: String; let score: Double; let firm: Bool }
    let startedAt: Double; let endedAt: Double; let dist: Double; let points: [Pt]; let sightings: [Sgt]
    let probs: [[Double]]; let regionKey: String?
    let dets: [[Box]]; let visible: [Double]
    let coarsen: [[Double]]
}
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let inp = try! JSONDecoder().decode(Input.self, from: data)
let cat = SpeciesCatalog()
var out: [String: Any] = [:]
out["classes"] = cat.classes.count
out["regions"] = cat.regions.count
out["info"] = cat.info.count
out["kruger"] = cat.region(for: CLLocationCoordinate2D(latitude: -24.0, longitude: 31.5))?.key ?? "nil"
out["nowhere"] = cat.region(for: CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0))?.key ?? "nil"
out["sensitive"] = [cat.isSensitive(name: "Nashorn"), cat.isSensitive(name: "Breitmaulnashorn"), cat.isSensitive(name: "Zebra")]
let region = inp.regionKey.flatMap { k in cat.regions.first { $0.key == k } }
out["decisions"] = inp.probs.map { p -> [String: Any] in
    let pr = cat.applyPrior(p, region: region)
    let d = SpeciesDecision.decide(pr, catalog: cat)
    return ["name": d.name ?? NSNull(), "key": d.key ?? NSNull(), "conf": (d.confidence * 1e6).rounded() / 1e6, "sure": d.sure, "other": d.other, "sum": (pr.reduce(0, +) * 1e6).rounded() / 1e6]
}
// Zusammenführung und Tracker
let vis = CGRect(x: inp.visible[0], y: inp.visible[1], width: inp.visible[2], height: inp.visible[3])
let tracker = Tracker()
var frames: [[String: Any]] = []
for (fi, f) in inp.dets.enumerated() {
    let dets = f.map { Detection(box: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), cls: $0.cls, score: $0.score, firm: $0.firm) }
    let merged = VisionPipeline.merge(dets)
    tracker.update(with: merged, visible: vis, now: Double(fi) * 0.1)
    func r4(_ v: CGFloat) -> Double { (Double(v) * 1e4).rounded() / 1e4 }
    frames.append(["merged": merged.map { [r4($0.box.minX), r4($0.box.minY), r4($0.box.width), r4($0.box.height), $0.cls, $0.firm] as [Any] },
                   "tracks": tracker.tracks.map { ["id": $0.id, "hits": $0.hits, "missed": $0.missed, "firm": $0.firm, "box": [r4($0.box.minX), r4($0.box.minY), r4($0.box.width), r4($0.box.height)], "shown": $0.isShown] as [String: Any] }])
}
out["frames"] = frames
out["tiles"] = VisionPipeline.tileGrid(vis, n: 3).map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
let sq = VisionPipeline.cropSquare(CGRect(x: 1500, y: 900, width: 300, height: 120), in: CGSize(width: 1920, height: 1080))
out["square"] = [Double(sq.minX), Double(sq.minY), Double(sq.width)]
// Fahrtstatistik
let pts = inp.points.map { TrackPoint(t: $0.t, lat: $0.lat, lon: $0.lon, spd: $0.spd, alt: $0.alt) }
let sg = inp.sightings.map { Sighting(name: $0.name, t: Date(timeIntervalSince1970: $0.t)) }
let st = DriveStats.compute(points: pts, startedAt: Date(timeIntervalSince1970: inp.startedAt), endedAt: Date(timeIntervalSince1970: inp.endedAt), dist: inp.dist, sightings: sg)
out["stats"] = ["dist": st.dist, "dur": st.dur, "moving": st.moving, "standing": st.standing, "maxSpeed": (st.maxSpeed * 1e4).rounded() / 1e4, "avgMoving": (st.avgMoving * 1e4).rounded() / 1e4, "elev": st.elev,
                "stops": st.stops.map { ["t0": $0.t0.timeIntervalSince1970, "t1": $0.t1.timeIntervalSince1970, "dur": $0.dur, "lat": $0.lat, "lon": $0.lon, "n": $0.sightings.count] },
                "splits": st.splits.map { ["km": $0.km, "time": $0.time, "at": $0.at.timeIntervalSince1970] }]
out["coarsen"] = inp.coarsen.map { let p = Position.coarsen(lat: $0[0], lon: $0[1]); return [(p.lat * 1e9).rounded() / 1e9, (p.lon * 1e9).rounded() / 1e9] }
let js = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try! js.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("ok")
