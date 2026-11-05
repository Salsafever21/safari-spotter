import XCTest
import SwiftData
import ImageIO
import CoreLocation
import UniformTypeIdentifiers
@testable import SafariSpotter

/// Gemeinsame Hilfen: SwiftData nur im Speicher (berührt die Daten der App nicht), echter Artenkatalog aus dem App-Bundle
class StoreTestCase: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var store: SightingStore!
    let catalog = SpeciesCatalog.shared
    let exact = (lat: -24.98765, lon: 31.54321)   // Kruger-Park

    override func setUpWithError() throws {
        container = try ModelContainer(for: Sighting.self, PhotoItem.self, Correction.self, Drive.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        store = SightingStore(context: context, catalog: catalog)
    }

    var exactPosition: Position { Position(lat: exact.lat, lon: exact.lon, acc: 5, coarse: false) }
    var coarsePosition: Position { Position.coarsen(lat: exact.lat, lon: exact.lon) }
    func isSensitive(_ name: String) -> Bool { catalog.isSensitive(name: name) }

    @discardableResult
    func addSighting(_ name: String, n: Int = 1, position: Position? = nil) -> Sighting {
        let s = Sighting(name: name, key: catalog.cls(name: name)?.key, n: n, position: position ?? exactPosition)
        context.insert(s); try? context.save()
        return s
    }

    @discardableResult
    func addPhoto(species: [String], dets: [PhotoDet] = [], position: Position? = nil, located: Bool = true, sightingIds: [UUID]) -> PhotoItem {
        let p = PhotoItem(t: .now, kind: "auto", species: species, dets: dets, image: Self.jpeg(), thumb: nil, width: 8, height: 8,
                          position: located ? (position ?? exactPosition) : nil, sightingIds: sightingIds)
        context.insert(p); try? context.save()
        return p
    }

    func allSightings() -> [Sighting] { (try? context.fetch(FetchDescriptor<Sighting>())) ?? [] }

    /// Kleines JPEG, optional mit GPS (und Höhe) in den Bildinformationen
    static func jpeg(gps: CLLocationCoordinate2D? = nil) -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let g = gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(g.latitude), kCGImagePropertyGPSLatitudeRef: g.latitude < 0 ? "S" : "N",
                                                    kCGImagePropertyGPSLongitude: abs(g.longitude), kCGImagePropertyGPSLongitudeRef: g.longitude < 0 ? "W" : "E",
                                                    kCGImagePropertyGPSAltitude: 312.0] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }
}
