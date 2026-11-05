import XCTest
@testable import SafariSpotter

final class NativeArchiveTests: XCTestCase {
    func testClipsSurviveArchiveRoundTripAndRepeatedInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clips = root.appendingPathComponent("Clips")
        let restored = root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let core = root.appendingPathComponent("core.ssbackup")
        let coreBytes = Data("SSBK1\nexample".utf8)
        try coreBytes.write(to: core)
        let id = UUID().uuidString
        let metadata = Data("{\"id\":\"\(id)\"}".utf8)
        let video = Data((0..<2_100_000).map { UInt8(truncatingIfNeeded: $0) })
        try metadata.write(to: clips.appendingPathComponent("\(id).json"))
        try video.write(to: clips.appendingPathComponent("\(id).mov"))

        let archive = try NativeArchive.create(core: core, clipsDirectory: clips)
        defer { try? FileManager.default.removeItem(at: archive) }
        let extracted = try NativeArchive.extract(archive)
        defer { extracted.removeTemporaryFiles() }
        XCTAssertEqual(try Data(contentsOf: extracted.core), coreBytes)
        XCTAssertEqual(extracted.clips.count, 2)
        try NativeArchive.installClips(extracted, clipsDirectory: restored)
        try NativeArchive.installClips(extracted, clipsDirectory: restored)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("\(id).mov")), video)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("\(id).json")), metadata)
    }

    func testDamagedClipIsRejectedBeforeRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = root.appendingPathComponent("core.ssbackup")
        try Data("SSBK1\nexample".utf8).write(to: core)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: clips.appendingPathComponent("\(UUID().uuidString).mov"))
        let archive = try NativeArchive.create(core: core, clipsDirectory: clips)
        defer { try? FileManager.default.removeItem(at: archive) }
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: archive)
        XCTAssertThrowsError(try NativeArchive.extract(archive))
    }
}
