import Foundation
import Vision
import CoreML

/// Prüft den Core-ML-Artenkopf auf lokalen, nach Art sortierten Fotos.
/// Aufruf: swift main.swift <SafariSpotterSpecies.mlpackage> <training/data> [Art-Schlüssel]
/// Die Fotos können mit dem Trainingssatz überlappen. Das ist ein Funktionstest,
/// keine unabhängige Aussage zur Genauigkeit im Feld.
guard CommandLine.arguments.count >= 3 else {
    fputs("Aufruf: swift main.swift <Modell.mlpackage> <Bilderordner> [Art-Schlüssel]\n", stderr)
    exit(2)
}

let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let dataURL = URL(fileURLWithPath: CommandLine.arguments[2])
let only = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
let configuration = MLModelConfiguration()
configuration.computeUnits = .all
let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
let fileManager = FileManager.default

var total = 0, top1 = 0, top3 = 0, unreadable = 0
var confusions: [String: Int] = [:]
let folders = try fileManager.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: [.isDirectoryKey])
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .filter { only == nil || $0.lastPathComponent == only }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for folder in folders {
    let expected = folder.lastPathComponent
    let photos = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var seen = 0, correct = 0, near = 0
    for photo in photos {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(url: photo).perform([request])
            guard let results = request.results as? [VNClassificationObservation], !results.isEmpty else {
                unreadable += 1; continue
            }
            seen += 1
            let best = results[0].identifier
            if best == expected { correct += 1 }
            else { confusions["\(expected) → \(best)", default: 0] += 1 }
            if results.prefix(3).contains(where: { $0.identifier == expected }) { near += 1 }
        } catch {
            unreadable += 1
        }
    }
    total += seen; top1 += correct; top3 += near
    print("\(expected): \(correct)/\(seen) Top 1, \(near)/\(seen) Top 3")
    fflush(stdout)
}

print("Gesamt: \(top1)/\(total) Top 1, \(top3)/\(total) Top 3; \(unreadable) nicht lesbar")
for (pair, count) in confusions.sorted(by: { $0.value > $1.value }).prefix(12) {
    print("\(pair): \(count)")
}
