import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Umrechnungen zwischen den Koordinatensystemen der App.
///
/// Die App rechnet überall (Tracker, Overlay, Sichtungen, die übernommene Web-App-Logik) in Pixeln mit Ursprung **oben links**.
/// Core Image hat den Ursprung **unten links**, Vision liefert Rahmen normiert auf den Ausschnitt, ebenfalls mit Ursprung unten links.
/// Jeder Zugriff auf ein `CIImage` mit einem App-Rechteck muss deshalb über `ciRect` gehen, sonst landen Kacheln und Artenkopf
/// bei Tieren ausserhalb der Bildmitte im vertikal gespiegelten Bildbereich.
///
/// Nur Foundation, damit `ios/Tools/unit-check` die Datei auch ohne iOS-SDK prüfen kann.
enum ImageGeometry {
    /// App-Rechteck (Pixel, oben links) → Rechteck im Koordinatensystem von Core Image für ein Bild mit Ausdehnung `extent`
    static func ciRect(_ r: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + r.minX, y: extent.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Vision-Rahmen (normiert auf den Ausschnitt `region`, Ursprung unten links) → Pixel im Gesamtbild (Ursprung oben links)
    static func pixelRect(fromVision b: CGRect, region: CGRect) -> CGRect {
        CGRect(x: region.minX + b.minX * region.width, y: region.minY + (1 - b.maxY) * region.height,
               width: b.width * region.width, height: b.height * region.height)
    }

    /// Skalierung der Vorschau, die den Bildschirm mit Aspect-Fill füllt
    static func fillScale(frame: CGSize, viewSize: CGSize) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        return max(viewSize.width / frame.width, viewSize.height / frame.height)
    }

    /// Sichtbarer Teil des Kamerabilds bei Aspect-Fill, zentriert (wie `visibleRegion()` in app.js; der Zoom steckt auf iOS
    /// schon im Kamerabild). Ohne bekannte Bildschirmgrösse das ganze Bild.
    static func visibleRegion(frame: CGSize, viewSize: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, viewSize.width > 0, viewSize.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let s = fillScale(frame: frame, viewSize: viewSize)
        let w = min(frame.width, viewSize.width / s), h = min(frame.height, viewSize.height / s)
        return CGRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2, width: w, height: h)
    }

    /// Punkt auf dem Bildschirm → Punkt im Kamerabild (Aspect-Fill, zentriert), für den Tipp auf einen Rahmen
    static func imagePoint(fromView p: CGPoint, viewSize: CGSize, frame: CGSize) -> CGPoint {
        let s = fillScale(frame: frame, viewSize: viewSize)
        let offX = (frame.width * s - viewSize.width) / 2, offY = (frame.height * s - viewSize.height) / 2
        return CGPoint(x: (p.x + offX) / s, y: (p.y + offY) / s)
    }
}
