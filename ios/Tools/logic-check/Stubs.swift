import Foundation
// Minimale Ersatztypen für iOS-Frameworks, nur für den Logik-Abgleich auf Linux
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double; init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude } }
final class CLLocation {
    let coordinate: CLLocationCoordinate2D; let horizontalAccuracy: Double
    init(latitude: Double, longitude: Double) { coordinate = .init(latitude: latitude, longitude: longitude); horizontalAccuracy = 5 }
    func distance(from b: CLLocation) -> Double {
        let toR = Double.pi / 180, dLat = (b.coordinate.latitude - coordinate.latitude) * toR, dLon = (b.coordinate.longitude - coordinate.longitude) * toR
        let s = pow(sin(dLat / 2), 2) + cos(coordinate.latitude * toR) * cos(b.coordinate.latitude * toR) * pow(sin(dLon / 2), 2)
        return 2 * 6371000 * asin(sqrt(s))
    }
}
protocol ObservableObject: AnyObject {}
final class Sighting { var id = UUID(); var name: String; var t: Date; var n: Int; init(name: String, t: Date, n: Int = 1) { self.name = name; self.t = t; self.n = n } }
