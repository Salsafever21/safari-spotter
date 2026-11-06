import XCTest
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
        XCTAssertEqual(firstItem["img"] as? String, "data:image/jpeg;base64," + image.base64EncodedString())
        XCTAssertEqual(firstItem["predicted"] as? String, "Löwe")
        XCTAssertEqual(firstItem["region"] as? String, "kruger")
    }

    func testEmptyExportIsRejected() throws {
        XCTAssertThrowsError(try CorrectionExporter.create([]))
    }
}
