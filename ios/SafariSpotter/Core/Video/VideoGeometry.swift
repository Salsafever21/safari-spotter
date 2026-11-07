import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Farben der Rahmen, gleiche Reihenfolge wie im Web und im Live-Overlay (`OverlayView.colors`)
enum TrackPalette {
    static let hex: [UInt32] = [0xf0a93a, 0x5ec8f2, 0x9be36a, 0xf27ab0, 0xc9a3ff, 0x55e0c8, 0xffd166, 0xff9f6e]
    static func rgb(_ index: Int) -> (r: Double, g: Double, b: Double) {
        let h = hex[((index % hex.count) + hex.count) % hex.count]
        return (Double((h >> 16) & 0xff) / 255, Double((h >> 8) & 0xff) / 255, Double(h & 0xff) / 255)
    }
}

/// Reine Rechnungen für die Videoaufnahme (ohne AVFoundation, prüfbar mit ios/Tools/unit-check)
enum VideoGeometry {
    /// Wie die Web-App: Aufnahme höchstens Full HD (längste Seite 1920), auch wenn die Kamera in 4K läuft
    static let maxLongSide: CGFloat = 1920

    /// Ausgabegrösse: Seitenverhältnis des Kamerabilds, längste Seite höchstens `maxLongSide`, gerade Pixelzahlen (Encoder)
    static func outputSize(for frame: CGSize, maxLongSide: CGFloat = maxLongSide) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let k = min(1, maxLongSide / max(frame.width, frame.height))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * k / 2).rounded(.down) * 2) }
        return CGSize(width: even(frame.width), height: even(frame.height))
    }

    /// Rahmen aus Kamerabild-Pixeln (oben links) in Ausgabepixel (oben links)
    static func scale(_ r: CGRect, from frame: CGSize, to output: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let sx = output.width / frame.width, sy = output.height / frame.height
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    /// Grösse eines "Punkts" im Video, damit Linien und Schrift so wirken wie im Live-Overlay auf einem 393 pt breiten iPhone
    static func pointScale(output: CGSize) -> CGFloat {
        max(1, min(output.width, output.height) / 393)
    }

    /// Lage der Namensplakette: über dem Rahmen, bei Platzmangel innen oben; immer ganz im Bild
    static func labelOrigin(box: CGRect, label: CGSize, in output: CGSize, gap: CGFloat) -> CGPoint {
        var y = box.minY - label.height - gap
        if y < 0 { y = box.minY + gap }
        let x = min(max(0, box.minX), max(0, output.width - label.width))
        return CGPoint(x: x, y: min(max(0, y), max(0, output.height - label.height)))
    }

    /// Bitrate: HEVC rund 0,16 Bit pro Pixel und Bild, H.264 0,25 (1080×1920 bei 30 fps ≈ 10 bzw. 15,6 Mbit/s)
    static func bitrate(for size: CGSize, fps: Double = 30, hevc: Bool) -> Int {
        Int((Double(size.width * size.height) * fps * (hevc ? 0.16 : 0.25)).rounded())
    }

    /// Anzeige der Aufnahmedauer: "00:42", "12:05", ab einer Stunde "1:02:03"
    static func timerText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s / 60) % 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
    }
}
