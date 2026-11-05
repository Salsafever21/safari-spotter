import Foundation
// Minimale Ersatztypen für iOS-Frameworks, nur für ios/Tools/unit-check (läuft ohne iOS-SDK, auch auf Linux)
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double; init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude } }
final class CLLocation {
    let coordinate: CLLocationCoordinate2D; let horizontalAccuracy: Double
    init(latitude: Double, longitude: Double, accuracy: Double = 5) { coordinate = .init(latitude: latitude, longitude: longitude); horizontalAccuracy = accuracy }
}
protocol ObservableObject: AnyObject {}
