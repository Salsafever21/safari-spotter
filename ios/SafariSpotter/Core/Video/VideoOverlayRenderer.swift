import UIKit

/// Zeichnet Rahmen, Namen und Zeitstempel für das eingebrannte Video, in derselben Optik wie das Live-Overlay und
/// `drawOverlay()` der Web-App (Rahmen gestrichelt, solange unsicher, Eckwinkel, Plakette über dem Rahmen).
/// Läuft auf der Video-Queue; `UIGraphicsImageRenderer` und das Zeichnen von Text darin sind ausserhalb des Hauptthreads erlaubt.
enum VideoOverlayRenderer {
    static func image(tracks: [CameraController.TrackSnapshot], frameSize: CGSize, output: CGSize, labels: Bool, stamp: String?) -> CGImage? {
        guard output.width > 0, output.height > 0, !(tracks.isEmpty && stamp == nil) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        format.preferredRange = .standard   // 8-Bit sRGB wie das Video, nicht der erweiterte P3-Bereich des Displays
        let px = VideoGeometry.pointScale(output: output)
        let image = UIGraphicsImageRenderer(size: output, format: format).image { _ in
            for t in tracks {
                let r = VideoGeometry.scale(t.box, from: frameSize, to: output)
                guard r.width > 1, r.height > 1 else { continue }
                let c = TrackPalette.rgb(t.colorIndex)
                let color = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
                color.setStroke()
                let frame = UIBezierPath(roundedRect: r, cornerRadius: 10 * px)
                frame.lineWidth = 2.2 * px
                if !t.sure { frame.setLineDash([7 * px, 5 * px], count: 2, phase: 0) }
                frame.stroke()
                let k = min(16 * px, r.width / 3, r.height / 3)
                let corners = UIBezierPath()
                corners.move(to: CGPoint(x: r.minX, y: r.minY + k)); corners.addLine(to: CGPoint(x: r.minX, y: r.minY)); corners.addLine(to: CGPoint(x: r.minX + k, y: r.minY))
                corners.move(to: CGPoint(x: r.maxX - k, y: r.minY)); corners.addLine(to: CGPoint(x: r.maxX, y: r.minY)); corners.addLine(to: CGPoint(x: r.maxX, y: r.minY + k))
                corners.move(to: CGPoint(x: r.maxX, y: r.maxY - k)); corners.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); corners.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
                corners.move(to: CGPoint(x: r.minX + k, y: r.maxY)); corners.addLine(to: CGPoint(x: r.minX, y: r.maxY)); corners.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
                corners.lineWidth = 4 * px
                corners.stroke()
                if labels { drawChip(name: t.name, sub: t.sub, fill: t.sure ? color : nil, box: r, output: output, px: px) }
            }
            if let stamp { drawStamp(stamp, output: output, px: px) }
        }
        return image.cgImage
    }

    private static func drawChip(name: String, sub: String, fill: UIColor?, box: CGRect, output: CGSize, px: CGFloat) {
        let text: UIColor = fill == nil ? .white : .black
        let nameText = NSAttributedString(string: name, attributes: [.font: UIFont.systemFont(ofSize: 14 * px, weight: .semibold), .foregroundColor: text])
        let subText = NSAttributedString(string: sub, attributes: [.font: UIFont.systemFont(ofSize: 11 * px, weight: .medium), .foregroundColor: text.withAlphaComponent(0.75)])
        let ns = nameText.size(), ss = subText.size()
        let padX = 8 * px, padY = 4 * px, gap = 7 * px
        let size = CGSize(width: padX * 2 + ns.width + gap + ss.width, height: padY * 2 + max(ns.height, ss.height))
        let origin = VideoGeometry.labelOrigin(box: box, label: size, in: output, gap: 4 * px)
        (fill ?? UIColor.black.withAlphaComponent(0.8)).setFill()
        UIBezierPath(roundedRect: CGRect(origin: origin, size: size), cornerRadius: 7 * px).fill()
        nameText.draw(at: CGPoint(x: origin.x + padX, y: origin.y + (size.height - ns.height) / 2))
        subText.draw(at: CGPoint(x: origin.x + padX + ns.width + gap, y: origin.y + (size.height - ss.height) / 2))
    }

    private static func drawStamp(_ stamp: String, output: CGSize, px: CGFloat) {
        let font = UIFont.systemFont(ofSize: 13 * px, weight: .medium)
        let shadow = NSAttributedString(string: stamp, attributes: [.font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.45)])
        let text = NSAttributedString(string: stamp, attributes: [.font: font, .foregroundColor: UIColor(red: 244 / 255, green: 240 / 255, blue: 230 / 255, alpha: 0.9)])
        let size = text.size(), margin = 12 * px
        let origin = CGPoint(x: output.width - size.width - margin, y: output.height - size.height - margin)
        shadow.draw(at: CGPoint(x: origin.x + px, y: origin.y + px))
        text.draw(at: origin)
    }
}
