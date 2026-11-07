import Foundation
import CreateML

// Train only on an audited export from export_create_ml.js. No third-party detector weights.
guard CommandLine.arguments.count == 3 else {
    fputs("Aufruf: swift train_create_ml.swift <dataset/create_ml> <neues-modell.mlmodel>\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: output.path) else {
    fputs("Modellziel existiert bereits und wird nicht überschrieben: \(output.path)\n", stderr)
    exit(1)
}
let train = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: input.appendingPathComponent("train", isDirectory: true))
let validation = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: input.appendingPathComponent("val", isDirectory: true))
let parameters = MLObjectDetector.ModelParameters(validation: .dataSource(validation), batchSize: nil, maxIterations: nil)
let model = try MLObjectDetector(trainingData: train, parameters: parameters,
                                 annotationType: .boundingBox(units: .normalized, origin: .topLeft, anchor: .center))
print("Training:", model.trainingMetrics)
print("Validierung:", model.validationMetrics)
try model.write(to: output)
print("Core-ML-Modell:", output.path)
