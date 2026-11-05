import Foundation
import CryptoKit

/// Adds the native clip files to a complete SSBK1 backup before encryption.
/// SSBN1: magic(6), manifest length(8 LE), JSON manifest, SSBK1 bytes, clip bytes.
enum NativeArchive {
    struct Contents {
        let directory: URL
        let core: URL
        let clips: [URL]

        func removeTemporaryFiles() { try? FileManager.default.removeItem(at: directory) }
    }

    enum ArchiveError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): return "Native Sicherung ungültig: \(detail)" }
        }
    }

    private struct Entry: Codable {
        let name: String
        let length: UInt64
        let sha256: String
    }

    private struct Manifest: Codable {
        let version: Int
        let core: Entry
        let clips: [Entry]
    }

    private static let magic = Data("SSBN1\n".utf8)
    private static let bufferSize = 1_048_576
    private static let maxFileSize: UInt64 = 20_000_000_000

    static func isNative(_ url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try input.read(upToCount: magic.count) == magic
    }

    static func create(core: URL, clipsDirectory: URL) throws -> URL {
        let manager = FileManager.default
        let candidates = manager.fileExists(atPath: clipsDirectory.path)
            ? try manager.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.fileSizeKey]) : []
        let clips = candidates.filter { validClipName($0.lastPathComponent) && !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let coreEntry = try entry(for: core, name: "core.ssbackup")
        let clipEntries = try clips.map { try entry(for: $0, name: $0.lastPathComponent) }
        let manifest = try JSONEncoder().encode(Manifest(version: 1, core: coreEntry, clips: clipEntries))
        guard manifest.count <= 10_000_000 else { throw ArchiveError.invalid("Manifest zu gross") }
        let destination = manager.temporaryDirectory.appendingPathComponent("safari-spotter-native-\(UUID().uuidString).ssbackup")
        guard manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.write(contentsOf: magic)
            try output.write(contentsOf: Data(littleBytes(UInt64(manifest.count))))
            try output.write(contentsOf: manifest)
            try append(core, expected: coreEntry, to: output)
            for (file, entry) in zip(clips, clipEntries) { try append(file, expected: entry, to: output) }
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    static func extract(_ source: URL) throws -> Contents {
        let manager = FileManager.default
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try read(input, count: 6) == magic,
              let lengthBytes = try read(input, count: 8) else { throw ArchiveError.invalid("Dateikopf") }
        let manifestLength = uint64(lengthBytes)
        guard manifestLength > 0, manifestLength <= 10_000_000,
              let manifestBytes = try read(input, count: Int(manifestLength)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestBytes),
              manifest.version == 1, manifest.core.name == "core.ssbackup",
              manifest.clips.count <= 100_000,
              manifest.clips.allSatisfy({ validClipName($0.name) }),
              Set(manifest.clips.map(\.name)).count == manifest.clips.count else {
            throw ArchiveError.invalid("Manifest")
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("safari-spotter-restore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let core = directory.appendingPathComponent(manifest.core.name)
            try extractFile(manifest.core, from: input, to: core)
            var clips: [URL] = []
            for entry in manifest.clips {
                let url = directory.appendingPathComponent(entry.name)
                try extractFile(entry, from: input, to: url)
                clips.append(url)
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw ArchiveError.invalid("Unerwartete Daten") }
            return Contents(directory: directory, core: core, clips: clips)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// Call before importing the core archive, so a name collision cannot cause a partial restore.
    static func checkClipCollisions(_ contents: Contents, clipsDirectory: URL) throws {
        for file in contents.clips {
            let existing = clipsDirectory.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: existing.path), try digest(existing) != digest(file) {
                throw ArchiveError.invalid("Clip-Konflikt: \(file.lastPathComponent)")
            }
        }
    }

    static func installClips(_ contents: Contents, clipsDirectory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try checkClipCollisions(contents, clipsDirectory: clipsDirectory)
        for file in contents.clips {
            let destination = clipsDirectory.appendingPathComponent(file.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            let staging = clipsDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                try manager.copyItem(at: file, to: staging)
                try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
                try manager.moveItem(at: staging, to: destination)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
        }
    }

    private static func validClipName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
            && ["mov", "jpg", "json"].contains(parts[1])
    }

    private static func entry(for url: URL, name: String) throws -> Entry {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, UInt64(size) <= maxFileSize else { throw ArchiveError.invalid("Dateigrösse") }
        return Entry(name: name, length: UInt64(size), sha256: try digest(url))
    }

    private static func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: bufferSize), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ url: URL, expected: Entry, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var count: UInt64 = 0
        var hash = SHA256()
        while let data = try input.read(upToCount: bufferSize), !data.isEmpty {
            count += UInt64(data.count)
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        guard count == expected.length,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw ArchiveError.invalid("Datei während der Sicherung geändert: \(expected.name)")
        }
    }

    private static func extractFile(_ entry: Entry, from input: FileHandle, to destination: URL) throws {
        guard entry.length <= maxFileSize,
              entry.sha256.count == 64,
              entry.sha256.allSatisfy({ $0.isHexDigit }) else { throw ArchiveError.invalid("Dateiangaben") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining = entry.length
        var hash = SHA256()
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(bufferSize)))
            guard let data = try read(input, count: count) else { throw ArchiveError.invalid("Datei unvollständig") }
            hash.update(data: data)
            try output.write(contentsOf: data)
            remaining -= UInt64(count)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw ArchiveError.invalid("Prüfsumme: \(entry.name)")
        }
    }

    private static func read(_ input: FileHandle, count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let part = try input.read(upToCount: count - result.count), !part.isEmpty else { return nil }
            result.append(part)
        }
        return result
    }

    private static func littleBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func uint64(_ bytes: Data) -> UInt64 {
        bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
}
