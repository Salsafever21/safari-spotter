import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else { fatalError("Aufruf: swift make-icon.swift <Quelle> <Ziel>") }
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let targetURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Quellbild konnte nicht geladen werden") }
guard let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("RGB-Kontext konnte nicht erstellt werden") }
context.setFillColor(CGColor(red: 12 / 255, green: 16 / 255, blue: 12 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Ausgabe konnte nicht erstellt werden")
}
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG konnte nicht geschrieben werden") }
