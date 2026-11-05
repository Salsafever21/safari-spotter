import Foundation
// Gezielte Prüfungen der reinen Swift-Regeln (ohne iOS-SDK): Bildkoordinaten Core Image ↔ App, sichtbarer Ausschnitt,
// Korrektur ohne Doppelsichtung, Artenschutz der Positionen. Aufruf über run.sh.

var failures = 0, checks = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FEHLER (main.swift:\(line)): \(what)") }
}
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool { near(a.minX, b.minX, eps) && near(a.minY, b.minY, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps) }
func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { near(a.x, b.x, eps) && near(a.y, b.y, eps) }

// MARK: 1. Core Image ↔ App-Koordinaten (Befund E1)
// Modell des Kamerabilds: Pufferzeile 0 ist oben. Core Image legt den Ursprung unten links, die CI-Zeile y gehört also
// zur Pufferzeile H - 1 - y. Ein App-Rechteck (oben links) muss nach der Umrechnung genau seine Pufferzeilen treffen.
let W: CGFloat = 1080, H: CGFloat = 1920
let extent = CGRect(x: 0, y: 0, width: W, height: H)
func bufferRows(ofCI r: CGRect) -> ClosedRange<Int> { Int(H - r.maxY)...(Int(H - r.minY) - 1) }
func rows(of r: CGRect) -> ClosedRange<Int> { Int(r.minY)...(Int(r.maxY) - 1) }

let topHalf = CGRect(x: 0, y: 0, width: W, height: H / 2)
expect(near(ImageGeometry.ciRect(topHalf, in: extent), CGRect(x: 0, y: H / 2, width: W, height: H / 2)), "obere Bildhälfte liegt in Core Image bei y = H/2 … H")
// Kacheln wie tileGrid (Breite 1/n + 15 %) oben, unten, Mitte, dazu ein beliebiger Rahmen am Rand
let probes: [CGRect] = [CGRect(x: 0, y: 0, width: 702, height: 1248), CGRect(x: 378, y: 672, width: 702, height: 1248),
                        CGRect(x: 0, y: 0, width: 518, height: 922), CGRect(x: 281, y: 499, width: 518, height: 922), CGRect(x: 40, y: 1700, width: 300, height: 180)]
for r in probes {
    expect(bufferRows(ofCI: ImageGeometry.ciRect(r, in: extent)) == rows(of: r), "Ausschnitt \(r) trifft seine Pufferzeilen")
}
// Nachweis des alten Fehlers: unverändert an Core Image gegeben, trifft eine Kachel oben die falschen Zeilen
expect(bufferRows(ofCI: probes[0]) != rows(of: probes[0]), "ohne Umrechnung wäre die obere Kachel gespiegelt (alter Fehler)")
// Bild mit verschobener Ausdehnung
expect(near(ImageGeometry.ciRect(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGRect(x: 5, y: 7, width: 100, height: 200)), CGRect(x: 5, y: 197, width: 10, height: 10)), "Ausdehnung mit Ursprung ≠ 0")

// Vision-Rahmen (normiert, unten links) → Pixel (oben links), auch als Rundweg
let region = CGRect(x: 100, y: 200, width: 400, height: 800)
expect(near(ImageGeometry.pixelRect(fromVision: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), region: region), CGRect(x: 200, y: 400, width: 200, height: 200)), "Vision → Pixel")
for r in [CGRect(x: 120, y: 210, width: 50, height: 40), CGRect(x: 300, y: 900, width: 190, height: 95)] {
    let b = CGRect(x: (r.minX - region.minX) / region.width, y: 1 - (r.maxY - region.minY) / region.height, width: r.width / region.width, height: r.height / region.height)
    expect(near(ImageGeometry.pixelRect(fromVision: b, region: region), r, 1e-9), "Rundweg Pixel → Vision → Pixel für \(r)")
}

// MARK: 2. Sichtbarer Ausschnitt (Befund E3), gleiche Formel wie visibleRegion() in app.js (ohne Digitalzoom)
func jsVisible(_ vw: CGFloat, _ vh: CGFloat, _ cw: CGFloat, _ ch: CGFloat) -> CGRect {
    let s = max(cw / vw, ch / vh); let w = min(vw, cw / s), h = min(vh, ch / s)
    return CGRect(x: (vw - w) / 2, y: (vh - h) / 2, width: w, height: h)
}
let portraitView = CGSize(width: 393, height: 852)
let vis = ImageGeometry.visibleRegion(frame: CGSize(width: 1080, height: 1920), viewSize: portraitView)
expect(near(vis, jsVisible(1080, 1920, 393, 852)), "Hochformat wie app.js")
expect(near(vis.minY, 0) && vis.width < 1080 && near(vis.midX, 540), "Hochformat: seitlich beschnitten, zentriert")
let land = ImageGeometry.visibleRegion(frame: CGSize(width: 1920, height: 1080), viewSize: CGSize(width: 852, height: 393))
expect(near(land, jsVisible(1920, 1080, 852, 393)) && near(land.minX, 0) && land.height < 1080, "Querformat: oben/unten beschnitten")
expect(near(ImageGeometry.visibleRegion(frame: CGSize(width: 1080, height: 1920), viewSize: .zero), CGRect(x: 0, y: 0, width: 1080, height: 1920)), "ohne Bildschirmgrösse das ganze Bild")
expect(near(ImageGeometry.visibleRegion(frame: CGSize(width: 1080, height: 1920), viewSize: CGSize(width: 540, height: 960)), CGRect(x: 0, y: 0, width: 1080, height: 1920)), "gleiches Seitenverhältnis: ganzes Bild")
// Tipp: Bildschirmmitte → Bildmitte, Bildschirmecke → Ecke des sichtbaren Ausschnitts
expect(near(ImageGeometry.imagePoint(fromView: CGPoint(x: 196.5, y: 426), viewSize: portraitView, frame: CGSize(width: 1080, height: 1920)), CGPoint(x: 540, y: 960), 1e-6), "Tipp in der Mitte")
expect(near(ImageGeometry.imagePoint(fromView: .zero, viewSize: portraitView, frame: CGSize(width: 1080, height: 1920)), vis.origin, 1e-6), "Tipp oben links = Ursprung des sichtbaren Ausschnitts")

// MARK: 3. Korrektur ohne Doppelsichtung (Befund D1, mit Abspaltung bei n > 1)
let sid = UUID()
expect(CorrectionAction.plan(existing: nil, existingCount: 0, isNone: false, isOther: false) == .logNew, "ohne Sichtung: genau eine neue")
expect(CorrectionAction.plan(existing: nil, existingCount: 0, isNone: true, isOther: false) == .nothing, "ohne Sichtung, Fehlalarm: nichts")
expect(CorrectionAction.plan(existing: nil, existingCount: 0, isNone: false, isOther: true) == .nothing, "ohne Sichtung, kein Safari-Tier: nichts")
expect(CorrectionAction.plan(existing: sid, existingCount: 1, isNone: false, isOther: false) == .rename(sid), "eine Sichtung: umbenennen, keine zweite")
expect(CorrectionAction.plan(existing: sid, existingCount: 1, isNone: false, isOther: true) == .rename(sid), "eine Sichtung, kein Safari-Tier: umbenennen wie app.js")
expect(CorrectionAction.plan(existing: sid, existingCount: 1, isNone: true, isOther: false) == .remove(sid), "eine Sichtung, Fehlalarm: entfernen")
expect(CorrectionAction.plan(existing: sid, existingCount: 3, isNone: false, isOther: false) == .split(sid), "zusammengefasst: ein Tier abspalten")
expect(CorrectionAction.plan(existing: sid, existingCount: 3, isNone: true, isOther: false) == .decrement(sid), "zusammengefasst, Fehlalarm: Anzahl senken")
expect(CorrectionAction.plan(existing: sid, existingCount: 2, isNone: false, isOther: true) == .decrement(sid), "zusammengefasst, kein Safari-Tier: Anzahl senken")

// MARK: 4. Artenschutz der Positionen (Befunde D2, D3, Export)
let catalog = SpeciesCatalog()
let isSensitive = { (n: String) in catalog.isSensitive(name: n) }
expect(catalog.classes.count == 65, "Katalog geladen (65 Klassen)")
expect(isSensitive("Breitmaulnashorn") && isSensitive("Spitzmaulnashorn") && isSensitive("Nashorn"), "Nashörner und Sammelname sind sensibel")
expect(!isSensitive("Elefant") && !isSensitive("Impala"), "andere Arten sind nicht sensibel")
expect(LocationProtection.containsSensitive(["Impala", nil, "Spitzmaulnashorn"], isSensitive: isSensitive), "Nashorn nur als Rahmen im Bild erkannt")
expect(LocationProtection.containsSensitive(["Impala", "Nashorn"], isSensitive: isSensitive), "Sammelname Nashorn erkannt")
expect(!LocationProtection.containsSensitive(["Impala", nil], isSensitive: isSensitive) && !LocationProtection.containsSensitive([], isSensitive: isSensitive), "ohne Nashorn nicht sensibel")

let exact = (lat: -24.98765, lon: 31.54321)
let coarse = Position.coarsen(lat: exact.lat, lon: exact.lon)
expect(LocationProtection.protectedPosition(lat: nil, lon: 31, coarse: false, sensitive: true) == nil, "ohne Koordinate keine Position")
if let p = LocationProtection.protectedPosition(lat: exact.lat, lon: exact.lon, coarse: false, sensitive: true) {
    expect(p.coarse && p.lat == coarse.lat && p.lon == coarse.lon, "sensibel → Mitte der 10-km-Zelle")
    let cell = 10000.0 / 111320.0
    expect(abs(p.lat - exact.lat) <= cell / 2 && (p.lat != exact.lat || p.lon != exact.lon), "vergröberte Position liegt in der Zelle, ist aber nicht die genaue")
} else { expect(false, "sensible Position fehlt") }
if let p = LocationProtection.protectedPosition(lat: exact.lat, lon: exact.lon, coarse: false, sensitive: false) {
    expect(!p.coarse && p.lat == exact.lat && p.lon == exact.lon, "harmlose Art bleibt genau")
} else { expect(false, "harmlose Position fehlt") }
// Bereits vergröbert: nie ein zweites Mal (coarsen ist beim Längengrad nicht idempotent)
if let p = LocationProtection.protectedPosition(lat: coarse.lat, lon: coarse.lon, coarse: true, sensitive: true) {
    expect(p.coarse && p.lat == coarse.lat && p.lon == coarse.lon, "schon vergröbert bleibt unverändert")
} else { expect(false, "vergröberte Position fehlt") }
let twice = Position.coarsen(lat: coarse.lat, lon: coarse.lon)
print("Hinweis: zweimal vergröbert weicht beim Längengrad um \(String(format: "%.2e", abs(twice.lon - coarse.lon)))° ab (darum nie doppelt vergröbern)")

expect(LocationProtection.renamedSpecies(["Elefant"], from: "Elefant", to: "Breitmaulnashorn") == ["Breitmaulnashorn"], "Fotoarten: umbenennen")
expect(LocationProtection.renamedSpecies(["Impala", "Elefant"], from: "Elefant", to: "Nashorn") == ["Impala", "Nashorn"], "Fotoarten: Reihenfolge bleibt")
expect(LocationProtection.renamedSpecies(["Impala"], from: "Elefant", to: "Nashorn") == ["Impala", "Nashorn"], "Fotoarten: neue Art ergänzt")
expect(LocationProtection.renamedSpecies(["Nashorn", "Elefant"], from: "Elefant", to: "Nashorn") == ["Nashorn"], "Fotoarten: keine Duplikate")

print(failures == 0 ? "unit-check: \(checks) Prüfungen bestanden." : "unit-check: \(failures) von \(checks) Prüfungen fehlgeschlagen.")
exit(failures == 0 ? 0 : 1)
