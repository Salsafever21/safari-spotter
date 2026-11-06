import XCTest
import AVFoundation
import CoreMedia
@testable import SafariSpotter

/// Ende-zu-Ende mit echtem AVAssetWriter: jedes Bild landet in der Datei, die Datei trägt keinen Standort,
/// 4K wird auf Full HD verkleinert, eingebrannte Rahmen sind sichtbar, leere Aufnahmen hinterlassen nichts, abgebrochene
/// Clips kommen zurück, und eine langsame Erkennung kostet über das echte Tor (`DetectionGate.route`) kein einziges Bild.
final class VideoRecorderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Hilfen (synchron, damit Schlafen und Sperren nicht in async-Kontexten stehen)

    private func info(burnIn: Bool = false, position: Position? = nil) -> VideoRecorder.StartInfo {
        VideoRecorder.StartInfo(directory: dir, burnIn: burnIn, labels: false, position: position, lens: "Weitwinkel",
                                trackingActive: false, stamp: nil)
    }

    /// Schwarzes BGRA-Bild wie von AVFoundation, Zeitstempel frame/30 s
    private func sampleBuffer(width: Int, height: Int, frame: Int) throws -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        let description = try XCTUnwrap(format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: description,
                                                                sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func audioSample(frame: Int) throws -> CMSampleBuffer {
        var desc = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &desc, layoutSize: 0, layout: nil,
                                                      magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                      formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        let bytes = 2_048
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                          blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                          dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
        let silence = [UInt8](repeating: 0, count: bytes)
        XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: silence, blockBuffer: try XCTUnwrap(block),
                                                     offsetIntoDestination: 0, dataLength: bytes), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame * 1_470), timescale: 44_100),
                                        decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: try XCTUnwrap(format),
                                                 sampleCount: 1_024, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    /// Bilder in Echtzeit (30 fps) liefern, wie die Kamera
    private func feed(_ recorder: VideoRecorder, frames: Int, width: Int, height: Int) throws {
        for i in 0..<frames {
            recorder.append(try sampleBuffer(width: width, height: height, frame: i))
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
    }

    /// Wie `CameraController.captureOutput`: jedes Bild über `DetectionGate.route`, jede Erkennung dauert `detectionTime`.
    /// Liefert die Zahl der Erkennungsdurchläufe.
    private func feedThroughGate(_ recorder: VideoRecorder, frames: Int, detectionTime: TimeInterval) throws -> Int {
        let gate = DetectionGate(); gate.setWanted(true)
        let detectQueue = DispatchQueue(label: "test.slow-detection")
        let lock = NSLock(); var detections = 0
        for i in 0..<frames {
            let sample = try sampleBuffer(width: 360, height: 640, frame: i)
            gate.route(record: { recorder.append(sample) }, detectOn: detectQueue) {
                Thread.sleep(forTimeInterval: detectionTime)
                lock.lock(); detections += 1; lock.unlock()
            }
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        detectQueue.sync {}
        lock.lock(); defer { lock.unlock() }
        return detections
    }

    private func stop(_ recorder: VideoRecorder) async throws -> ClipRecord? {
        try await withCheckedThrowingContinuation { continuation in
            recorder.stop(reason: .user) { continuation.resume(with: $0) }
        }
    }

    private func videoTrack(_ asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first)
    }

    private func sampleCount(_ asset: AVURLAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let s = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(s) }
        return count
    }

    /// RGBA-Pixel eines Bildes, Zeile 0 oben
    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }

    // MARK: Tests

    func testWritesEveryFrameWithoutLocationOrAudio() async throws {
        let recorder = VideoRecorder()
        let cell = Position.coarsen(lat: -24.98765, lon: 31.54321)
        recorder.start(info(position: cell))
        try feed(recorder, frames: 60, width: 360, height: 640)
        let result = try await stop(recorder)
        let r = try XCTUnwrap(result)

        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.frames, 60)
        XCTAssertEqual(r.droppedFrames, 0)
        XCTAssertEqual(r.width, 360); XCTAssertEqual(r.height, 640)
        XCTAssertEqual(r.duration, 2.0, accuracy: 0.05)
        XCTAssertTrue(r.coarse); XCTAssertEqual(r.lat, cell.lat); XCTAssertEqual(r.lon, cell.lon)
        let stored = try XCTUnwrap(ClipFiles.load(r.id, in: dir))
        XCTAssertEqual(stored.id, r.id)
        XCTAssertEqual(stored.state, r.state)
        XCTAssertEqual(stored.frames, r.frames)
        XCTAssertEqual(stored.fileSize, r.fileSize)
        XCTAssertEqual(stored.createdAt.timeIntervalSince1970, r.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(stored.lat), try XCTUnwrap(r.lat), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(stored.lon), try XCTUnwrap(r.lon), accuracy: 1e-9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipFiles.thumbnailURL(r.id, in: dir).path))

        let asset = AVURLAsset(url: ClipFiles.movieURL(r.id, in: dir))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.1)
        let track = try await videoTrack(asset)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 360, height: 640))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "ohne Ton")
        XCTAssertEqual(try sampleCount(asset, track: track), 60, "jedes gelieferte Bild steht in der Datei")

        var items = try await asset.load(.metadata)
        items += try await asset.load(.commonMetadata)
        for format in try await asset.load(.availableMetadataFormats) { items += try await asset.loadMetadata(for: format) }
        let location = items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.commonKey == .commonKeyLocation
                                        || ($0.identifier?.rawValue.lowercased().contains("location") ?? false) }
        XCTAssertFalse(location, "kein Standort in den Videometadaten")
        XCTAssertTrue(items.contains { $0.identifier == .quickTimeMetadataSoftware }, "Metadaten werden geschrieben und gelesen")
    }

    func testWritesMicrophoneAudioWhenEnabled() async throws {
        let recorder = VideoRecorder()
        var start = info()
        start.includeAudio = true
        recorder.start(start)
        for frame in 0..<30 {
            recorder.append(try sampleBuffer(width: 360, height: 640, frame: frame))
            recorder.appendAudio(try audioSample(frame: frame))
            try await Task.sleep(for: .milliseconds(33))
        }
        let stopped = try await stop(recorder)
        let clip = try XCTUnwrap(stopped)
        XCTAssertEqual(clip.state, .complete)
        let asset = AVURLAsset(url: ClipFiles.movieURL(clip.id, in: dir))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(try sampleCount(asset, track: XCTUnwrap(tracks.first)), 0)
    }

    func testDownscales4KToFullHD() async throws {
        let recorder = VideoRecorder()
        recorder.start(info())
        try feed(recorder, frames: 10, width: 2160, height: 3840)
        let result = try await stop(recorder)
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.width, 1080); XCTAssertEqual(r.height, 1920)
        XCTAssertEqual(r.frames, 10)
        let track = try await videoTrack(AVURLAsset(url: ClipFiles.movieURL(r.id, in: dir)))
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
    }

    func testBurnedInBoxIsVisibleAndSpeciesAreNoted() async throws {
        let recorder = VideoRecorder()
        recorder.start(info(burnIn: true))
        let box = CGRect(x: 60, y: 160, width: 240, height: 320)
        recorder.updateOverlay([CameraController.TrackSnapshot(id: 1, box: box, name: "Elefant", sub: "bestätigt", sure: true, colorIndex: 0)],
                               frameSize: CGSize(width: 360, height: 640))
        try feed(recorder, frames: 30, width: 360, height: 640)
        let result = try await stop(recorder)
        let r = try XCTUnwrap(result)
        XCTAssertTrue(r.burnedIn)
        XCTAssertEqual(r.species, ["Elefant"], "sicher erkannte Art während der Aufnahme")

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: ClipFiles.movieURL(r.id, in: dir)))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        let px = pixels(image), w = image.width
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
        // Eckwinkel oben links (4 px stark, Farbe #f0a93a): im Bereich deutlich orange
        var bestRed = 0, blueAtBest = 255
        for y in 156...166 { for x in 58...78 { let c = rgb(x, y); if c.r > bestRed { bestRed = c.r; blueAtBest = c.b } } }
        XCTAssertGreaterThan(bestRed, 120, "Rahmen im Video sichtbar")
        XCTAssertLessThan(blueAtBest, bestRed, "Rahmenfarbe orange, nicht grau")
        XCTAssertLessThan(rgb(180, 320).r, 50, "Bildmitte bleibt schwarz")
    }

    func testStopWithoutFramesLeavesNoFiles() async throws {
        let recorder = VideoRecorder()
        recorder.start(info())
        let result = try await stop(recorder)
        XCTAssertNil(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testInterruptedClipIsRecoveredAndGarbageMarkedDamaged() async throws {
        let recorder = VideoRecorder()
        recorder.start(info())
        try feed(recorder, frames: 30, width: 360, height: 640)
        let result = try await stop(recorder)
        var r = try XCTUnwrap(result)
        r.state = .recording   // wie nach einem Absturz mitten in der Aufnahme
        try ClipFiles.save(r, in: dir)
        let garbage = UUID()
        try Data("kein Video".utf8).write(to: ClipFiles.movieURL(garbage, in: dir))

        await ClipFiles.recoverInterrupted(in: dir, probe: ClipLibrary.probe)
        let recovered = try XCTUnwrap(ClipFiles.load(r.id, in: dir))
        XCTAssertEqual(recovered.state, .recovered)
        XCTAssertEqual(recovered.duration, 1.0, accuracy: 0.1)
        XCTAssertEqual(ClipFiles.load(garbage, in: dir)?.state, .damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipFiles.movieURL(garbage, in: dir).path), "nichts wird automatisch gelöscht")
    }

    func testCorruptMetadataDoesNotHideMovieOrDestroyOriginal() async throws {
        let id = UUID()
        let corrupt = Data("unlesbare Original-Metadaten".utf8)
        try corrupt.write(to: ClipFiles.metadataURL(id, in: dir))
        try Data("Videodatei".utf8).write(to: ClipFiles.movieURL(id, in: dir))

        XCTAssertEqual(ClipFiles.orphanMovies(in: dir), [id])
        let report = await ClipFiles.recoverInterrupted(in: dir) { _ in
            ClipProbe(duration: 2, width: 320, height: 240)
        }
        XCTAssertTrue(report.failedIDs.isEmpty)
        XCTAssertEqual(report.changed.map(\.id), [id])
        XCTAssertEqual(ClipFiles.load(id, in: dir)?.state, .recovered)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(id.uuidString + ".json.unreadable")), corrupt)
    }

    func testSlowDetectionNeverCostsVideoFrames() async throws {
        let recorder = VideoRecorder()
        recorder.start(info())
        let detections = try feedThroughGate(recorder, frames: 45, detectionTime: 0.2)
        let result = try await stop(recorder)
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.frames, 45, "alle Bilder im Video, obwohl die Erkennung 6× langsamer ist")
        XCTAssertEqual(r.droppedFrames, 0)
        XCTAssertLessThan(detections, 15, "die Erkennung nimmt nur freie Bilder (\(detections))")
    }
}
