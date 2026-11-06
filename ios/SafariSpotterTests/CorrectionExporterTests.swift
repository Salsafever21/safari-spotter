import XCTest
import UIKit
import CoreLocation
import CryptoKit
@testable import SafariSpotter

@MainActor
final class CorrectionExporterTests: XCTestCase {
    func testExportKeepsPreviousSnapshotWhenCorrectionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = StoreTestCase.jpeg()
        let correction = Correction(image: image, predicted: "Löwe", predKey: "lion", conf: 0.83,
                                    label: "Impala", labelKey: "impala", status: "corrected", region: "kruger")

        let first = try CorrectionExporter.create([correction], directory: directory)
        correction.label = "Leopard"
        let second = try CorrectionExporter.create([correction], directory: directory)

        XCTAssertNotEqual(first, second)
        let firstItem = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])?["items"] as? [[String: Any]])[0]
        let secondItem = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: second)) as? [String: Any])?["items"] as? [[String: Any]])[0]
        XCTAssertEqual(firstItem["label"] as? String, "Impala")
        XCTAssertEqual(secondItem["label"] as? String, "Leopard")
        let encoded = try XCTUnwrap(firstItem["img"] as? String)
        let prefix = "data:image/jpeg;base64,"
        XCTAssertTrue(encoded.hasPrefix(prefix))
        let exportedImage = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst(prefix.count))))
        XCTAssertNotNil(UIImage(data: exportedImage))
        XCTAssertEqual(firstItem["predicted"] as? String, "Löwe")
        XCTAssertEqual(firstItem["region"] as? String, "kruger")
        let originalHash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(firstItem["sourceJPEGHash"] as? String, originalHash)
        XCTAssertEqual(secondItem["sourceJPEGHash"] as? String, originalHash)
    }

    func testEmptyExportIsRejected() throws {
        XCTAssertThrowsError(try CorrectionExporter.create([]))
    }

    func testExportStripsGPSFromImportedCorrectionImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PhotoExporter.jpegWithMetadata(StoreTestCase.jpeg(), date: .now,
            coordinate: CLLocationCoordinate2D(latitude: -24.98, longitude: 31.54), description: "Test")
        XCTAssertNotNil(PhotoExporter.gpsCoordinate(of: source))
        let correction = Correction(image: source, predicted: "Nashorn", predKey: nil,
                                    conf: 0.8, label: "Breitmaulnashorn", status: "corrected", region: nil)

        let file = try CorrectionExporter.create([correction], directory: directory)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let items = try XCTUnwrap(payload["items"] as? [[String: Any]])
        let encoded = try XCTUnwrap(items.first?["img"] as? String)
        let image = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst("data:image/jpeg;base64,".count))))
        XCTAssertNotNil(UIImage(data: image))
        XCTAssertNil(PhotoExporter.gpsCoordinate(of: image))
    }

    func testCleanupRemovesOnlyStaleCorrectionExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let correction = Correction(image: StoreTestCase.jpeg(), predicted: "Löwe", predKey: nil,
                                    conf: 0.8, label: "Löwe", status: "confirmed", region: nil)
        let stale = try CorrectionExporter.create([correction], directory: directory)
        let current = try CorrectionExporter.create([correction], directory: directory)
        let unrelated = directory.appendingPathComponent("andere-daten.json")
        try Data("behalten".utf8).write(to: unrelated)
        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelated.path)

        try CorrectionExporter.removeStale(in: directory, before: Date().addingTimeInterval(-3600))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
