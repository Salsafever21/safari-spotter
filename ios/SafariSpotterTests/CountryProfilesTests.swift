import XCTest
@testable import SafariSpotter

final class CountryProfilesTests: XCTestCase {
    func testProfilesAreBundledAndReferToKnownModelClasses() {
        let catalog = SpeciesCatalog.shared
        XCTAssertEqual(catalog.countryProfiles.count, 10)
        XCTAssertEqual(Set(catalog.countryProfiles.map(\.code)).count, 10)
        for profile in catalog.countryProfiles {
            XCTAssertFalse(profile.featured.isEmpty, profile.code)
            XCTAssertFalse(profile.sources.isEmpty, profile.code)
            for key in profile.featured {
                XCTAssertNotNil(catalog.cls(key: key), "\(profile.code): \(key)")
            }
            let species = catalog.featuredClasses(for: profile.code)
            for habitat in AnimalHabitat.allCases {
                XCTAssertTrue(species.contains { catalog.habitats(for: $0.key).contains(habitat) },
                              "\(profile.code) has no \(habitat.rawValue) species")
            }
            for source in profile.sources {
                XCTAssertEqual(URL(string: source)?.scheme, "https", source)
            }
        }
        XCTAssertTrue(catalog.country("ZA")?.featured.contains("elefant") == true)
    }

    func testCountryBoostDoesNotSuppressOtherSpecies() {
        let catalog = SpeciesCatalog.shared
        guard let elephant = catalog.classes.firstIndex(where: { $0.key == "elefant" }),
              let meerkat = catalog.classes.firstIndex(where: { $0.key == "erdmaennchen" }) else {
            return XCTFail("Expected model classes missing")
        }
        var probabilities = [Double](repeating: 0, count: catalog.classes.count)
        probabilities[elephant] = 0.5
        probabilities[meerkat] = 0.5
        let adjusted = catalog.applyPrior(probabilities, region: nil, destinationCode: "ZA")
        XCTAssertGreaterThan(adjusted[elephant], 0.5)
        XCTAssertGreaterThan(adjusted[meerkat], 0)
        XCTAssertEqual(adjusted.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertEqual(catalog.applyPrior(probabilities, region: nil, destinationCode: "CH"), probabilities)
        let fromOrigin = catalog.applyPrior(probabilities, region: nil, originCode: "ZA", destinationCode: "CH")
        XCTAssertGreaterThan(fromOrigin[elephant], 0.5)
        XCTAssertLessThan(fromOrigin[elephant], adjusted[elephant])
    }

    func testHabitatsAllowGroundAirAndWater() {
        let catalog = SpeciesCatalog.shared
        XCTAssertTrue(catalog.habitats(for: "elefant").contains(.ground))
        XCTAssertTrue(catalog.habitats(for: "gaukler").contains(.air))
        XCTAssertFalse(catalog.habitats(for: "gaukler").contains(.ground))
        XCTAssertTrue(catalog.habitats(for: "flusspferd").contains(.water))
        XCTAssertTrue(catalog.habitats(for: "flamingo").contains(.air))
        XCTAssertTrue(catalog.habitats(for: "flamingo").contains(.water))
    }
}
