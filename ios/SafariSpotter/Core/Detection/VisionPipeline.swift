import Foundation
import Vision
import CoreML
import CoreImage
import CoreGraphics

/// Rohdetektion in Bildkoordinaten (Pixel, Ursprung oben links), wie in der Web-App
struct Detection {
    var box: CGRect
    var cls: String      // COCO-Klasse (oder "yolo:<art>" beim eigenen Detektor)
    var score: Double
    var firm: Bool       // sicher (Tierklasse, Score über Schwelle, nicht am Kachelrand)
    var species: [String: Double]? = nil   // Artwahrscheinlichkeiten direkt aus dem Detektor (nur YOLO-Pfad)
}

/// Die gleiche zweistufige Pipeline wie im Web: SSDLite-Detektor (COCO) findet Tiere, der Artenkopf bestimmt die Art.
/// Der Detektor rechnet mit 300×300 Pixeln, darum werden ferne Tiere zusätzlich in Kacheln gesucht (Fernerkennung).
///
/// YOLO-Pfad (training/yolo): Liegt `SafariSpotterYolo.mlmodelc` im Bundle (Xcode kompiliert `SafariSpotterYolo.mlpackage` dazu),
/// liefert dieser Detektor Rahmen und Art in einem Durchgang; der Artenkopf läuft dann nur noch als zweite Meinung.
final class VisionPipeline {
    static let animalCoco: Set<String> = ["bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"]
    static let blockedCoco: Set<String> = ["person", "bicycle", "car", "motorcycle", "bus", "train", "truck", "boat", "airplane"]

    private let detector: VNCoreMLModel
    private let classifier: VNCoreMLModel
    private let yolo: VNCoreMLModel?
    private let catalog: SpeciesCatalog
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    var usesYolo: Bool { yolo != nil }

    init(catalog: SpeciesCatalog) throws {
        self.catalog = catalog
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all   // Neural Engine, wo möglich
        // Die Klassen SafariSpotterDetector / SafariSpotterSpecies erzeugt Xcode aus den Modelldateien
        detector = try VNCoreMLModel(for: SafariSpotterDetector(configuration: cfg).model)
        classifier = try VNCoreMLModel(for: SafariSpotterSpecies(configuration: cfg).model)
        // Optionaler eigener Detektor, ohne generierte Klasse geladen, damit das Projekt auch ohne ihn baut
        if let url = Bundle.main.url(forResource: "SafariSpotterYolo", withExtension: "mlmodelc"), let m = try? MLModel(contentsOf: url, configuration: cfg) {
            yolo = try? VNCoreMLModel(for: m)
        } else { yolo = nil }
    }

    // MARK: Detektor

    /// Detektiert in einem Ausschnitt (Pixelrechteck) des Bildes. Ergebnisse in Pixelkoordinaten des Gesamtbildes.
    func detect(in image: CIImage, region: CGRect, threshold: Double, isTile: Bool) throws -> [Detection] {
        let crop = image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        let request = VNCoreMLRequest(model: yolo ?? detector)
        request.imageCropAndScaleOption = .scaleFill   // wie im Web: Ausschnitt auf die Modellgrösse gestaucht
        let handler = VNImageRequestHandler(ciImage: crop, orientation: .up, options: [:])
        try handler.perform([request])
        let minScore = max(0.12, threshold * 0.4)
        var out: [Detection] = []
        for obs in request.results as? [VNRecognizedObjectObservation] ?? [] {
            guard let top = obs.labels.first, Double(top.confidence) >= minScore, !Self.blockedCoco.contains(top.identifier) else { continue }
            // Vision: normiert, Ursprung unten links → Pixel, Ursprung oben links
            let b = obs.boundingBox
            let box = CGRect(x: region.minX + b.minX * region.width,
                             y: region.minY + (1 - b.maxY) * region.height,
                             width: b.width * region.width, height: b.height * region.height)
            let edge = isTile && (b.minX < 0.01 || b.minY < 0.01 || b.maxX > 0.99 || b.maxY > 0.99)
            // Kacheln sind für kleine Tiere da: grosse, angeschnittene Rahmen am Rand verwirft der Vollbild-Durchlauf besser
            if edge && (b.width > 0.5 || b.height > 0.5) { continue }
            if yolo != nil {
                // Eigener Detektor: Labels sind die Artschlüssel (training/species.json), jede Box ist ein Tier
                let firm = Double(top.confidence) >= threshold && !edge
                let species = Dictionary(obs.labels.map { ($0.identifier, Double($0.confidence)) }, uniquingKeysWith: { a, _ in a })
                out.append(Detection(box: box, cls: "yolo:" + top.identifier, score: Double(top.confidence), firm: firm, species: species))
            } else {
                let firm = Self.animalCoco.contains(top.identifier) && Double(top.confidence) >= threshold && !edge
                out.append(Detection(box: box, cls: top.identifier, score: Double(top.confidence), firm: firm))
            }
        }
        return out
    }

    /// Artwahrscheinlichkeiten eines YOLO-Treffers als Vektor in Katalogreihenfolge (fehlende Klassen = 0), Region angewendet
    func probs(fromDetector species: [String: Double], region: Region?) -> [Double] {
        var v = catalog.classes.map { species[$0.key] ?? 0 }
        let s = v.reduce(0, +); if s > 0 { v = v.map { $0 / s } }
        return catalog.applyPrior(v, region: region)
    }

    /// Vollbild plus optional n×n überlappende Kacheln (Fernerkennung), zusammengeführt
    func detectAll(in image: CIImage, visible: CGRect, threshold: Double, tiles n: Int) throws -> [Detection] {
        var dets = try detect(in: image, region: visible, threshold: threshold, isTile: false)
        if n > 0 {
            for t in Self.tileGrid(visible, n: n) { dets += try detect(in: image, region: t, threshold: threshold, isTile: true) }
        }
        return Self.merge(dets)
    }

    static func tileGrid(_ reg: CGRect, n: Int) -> [CGRect] {
        let fw = min(1, 1 / Double(n) + 0.15), fh = fw
        var tiles: [CGRect] = []
        for i in 0..<n { for j in 0..<n {
            let fx = n == 1 ? 0 : Double(i) / Double(n - 1) * (1 - fw), fy = n == 1 ? 0 : Double(j) / Double(n - 1) * (1 - fh)
            tiles.append(CGRect(x: reg.minX + fx * reg.width, y: reg.minY + fy * reg.height, width: fw * reg.width, height: fh * reg.height))
        } }
        return tiles
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b); if inter.isNull || inter.isEmpty { return 0 }
        let ia = Double(inter.width * inter.height)
        let u = Double(a.width * a.height + b.width * b.height) - ia
        return u > 0 ? ia / u : 0
    }
    static func containment(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b); if inter.isNull || inter.isEmpty { return 0 }
        let m = Double(min(a.width * a.height, b.width * b.height))
        return m > 0 ? Double(inter.width * inter.height) / m : 0
    }
    static func sameAnimal(_ a: CGRect, _ b: CGRect) -> Bool {
        let centerInside = b.contains(CGPoint(x: a.midX, y: a.midY)) || a.contains(CGPoint(x: b.midX, y: b.midY))
        return iou(a, b) > 0.45 || containment(a, b) > 0.7 || (centerInside && iou(a, b) > 0.12)
    }
    /// Zusammenführen wie im Web: sichere und grosse Rahmen zuerst, Teilrahmen gehen in ihnen auf
    static func merge(_ dets: [Detection]) -> [Detection] {
        let sorted = dets.sorted { ($0.firm ? 1 : 0, $0.box.width * $0.box.height) > ($1.firm ? 1 : 0, $1.box.width * $1.box.height) }
        var kept: [Detection] = []
        for d in sorted {
            if let i = kept.firstIndex(where: { sameAnimal($0.box, d.box) }) {
                if d.firm && !kept[i].firm { kept[i].firm = true; kept[i].cls = d.cls; kept[i].score = max(kept[i].score, d.score); kept[i].species = d.species ?? kept[i].species }
            } else { kept.append(d) }
        }
        return kept
    }

    // MARK: Artenkopf

    /// Quadratischer Ausschnitt um einen Rahmen (12 % Rand), wie cropSquare() im Web
    static func cropSquare(_ box: CGRect, in size: CGSize, pad: CGFloat = 0.12) -> CGRect {
        let side = min(max(box.width, box.height) * (1 + 2 * pad), size.width, size.height)
        let x = max(0, min(box.midX - side / 2, size.width - side)), y = max(0, min(box.midY - side / 2, size.height - side))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Wahrscheinlichkeiten je Klasse (in Katalogreihenfolge), Region als Vorwissen angewendet
    func classify(_ image: CIImage, square: CGRect, region: Region?) throws -> [Double] {
        let crop = image.cropped(to: square).transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
        let request = VNCoreMLRequest(model: classifier)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: crop, orientation: .up, options: [:]).perform([request])
        var probs = [Double](repeating: 0, count: catalog.classes.count)
        let index = Dictionary(uniqueKeysWithValues: catalog.classes.enumerated().map { ($1.key, $0) })
        for obs in request.results as? [VNClassificationObservation] ?? [] {
            if let i = index[obs.identifier] { probs[i] = Double(obs.confidence) }
        }
        return catalog.applyPrior(probs, region: region)
    }

    /// JPEG-Ausschnitt (224 px) für Korrekturen und Thumbnails
    func jpeg(_ image: CIImage, rect: CGRect, size: CGFloat = 224, quality: CGFloat = 0.8) -> Data? {
        let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: size / rect.width, y: size / rect.height))
        return ciContext.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }
}
