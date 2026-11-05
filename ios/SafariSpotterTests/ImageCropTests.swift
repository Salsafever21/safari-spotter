import XCTest
import CoreImage
import CoreVideo
@testable import SafariSpotter

/// Bildausschnitte in App-Koordinaten (Ursprung oben links) treffen im Kamerabild den richtigen Bereich (Befund E1).
/// Das Testbild ist ein BGRA-Puffer wie von AVFoundation: Zeile 0 ist oben, die obere Hälfte rot, die untere schwarz.
final class ImageCropTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let width = 100, height = 200   // so liegen die 2×2-Kacheln auf ganzen Pixeln (Höhe 130, zweite Reihe ab y = 70)

    private func cameraFrame() throws -> CIImage {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * bytesPerRow + x * 4
                p[0] = 0; p[1] = 0; p[2] = y < height / 2 ? 255 : 0; p[3] = 255   // B, G, R, A
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Anteil roter Pixel eines Bildes
    private func redShare(_ image: CIImage) -> Double {
        let b = image.extent.integral
        let w = Int(b.width), h = Int(b.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(image, toBitmap: &px, rowBytes: w * 4, bounds: b, format: .RGBA8, colorSpace: nil)
        var red = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] > 200 && px[i + 1] < 60 { red += 1 }
        return Double(red) / Double(w * h)
    }

    func testTopAndBottomHalf() throws {
        let img = try cameraFrame()
        XCTAssertEqual(redShare(VisionPipeline.crop(img, topLeft: CGRect(x: 0, y: 0, width: 100, height: 100))), 1, accuracy: 0.01, "obere Hälfte muss rot sein")
        XCTAssertEqual(redShare(VisionPipeline.crop(img, topLeft: CGRect(x: 0, y: 100, width: 100, height: 100))), 0, accuracy: 0.01, "untere Hälfte muss schwarz sein")
    }

    func testCropIsMovedToOrigin() throws {
        let c = VisionPipeline.crop(try cameraFrame(), topLeft: CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(c.extent, CGRect(x: 0, y: 0, width: 30, height: 40))
    }

    /// Fernerkennung: die obere Kachel sieht die obere, die untere Kachel die untere Bildpartie
    func testFarDetectionTilesSeeTheirOwnRows() throws {
        let img = try cameraFrame()
        let tiles = VisionPipeline.tileGrid(CGRect(x: 0, y: 0, width: 100, height: 200), n: 2)
        let top = try XCTUnwrap(tiles.first { $0.minX == 0 && $0.minY == 0 })
        let bottom = try XCTUnwrap(tiles.first { $0.minX == 0 && $0.minY > 0 })
        XCTAssertEqual(redShare(VisionPipeline.crop(img, topLeft: top)), Double((100 - top.minY) / top.height), accuracy: 0.03)          // ≈ 0,77
        XCTAssertEqual(redShare(VisionPipeline.crop(img, topLeft: bottom)), Double(max(0, 100 - bottom.minY) / bottom.height), accuracy: 0.03)  // ≈ 0,23
    }

    /// Artenkopf: der quadratische Ausschnitt folgt dem Tier, auch ausserhalb der Bildmitte
    func testSpeciesHeadCropFollowsTheAnimal() throws {
        let img = try cameraFrame()
        let size = img.extent.size
        let animalTop = CGRect(x: 30, y: 20, width: 30, height: 30), animalBottom = CGRect(x: 30, y: 150, width: 30, height: 30)
        XCTAssertGreaterThan(redShare(VisionPipeline.crop(img, topLeft: VisionPipeline.cropSquare(animalTop, in: size))), 0.95)
        XCTAssertLessThan(redShare(VisionPipeline.crop(img, topLeft: VisionPipeline.cropSquare(animalBottom, in: size))), 0.05)
    }

    /// Bildanalyse: Mediathek-Bild aufrecht, Ausdehnung ab (0, 0), Ausschnitte in denselben Koordinaten
    func testLibraryImageIsUprightWithOriginZero() throws {
        let cg = try XCTUnwrap(ctx.createCGImage(try cameraFrame(), from: CGRect(x: 0, y: 0, width: width, height: height)))
        let up = VisionPipeline.uprightImage(cg, exifOrientation: 1)
        XCTAssertEqual(up.extent.origin, .zero)
        XCTAssertGreaterThan(redShare(VisionPipeline.crop(up, topLeft: CGRect(x: 0, y: 0, width: 100, height: 100))), 0.95)
        let rotated = VisionPipeline.uprightImage(cg, exifOrientation: 6)
        XCTAssertEqual(rotated.extent.origin, .zero)
        XCTAssertEqual(rotated.extent.size, CGSize(width: height, height: width))
    }
}
