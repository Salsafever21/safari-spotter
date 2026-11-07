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

    func testCountryCannotTurnPetsOrUncertainImagesIntoSureWildlife() {
        let catalog = SpeciesCatalog.shared
        guard let elephant = catalog.classes.firstIndex(where: { $0.key == "elefant" }),
              let dog = catalog.classes.firstIndex(where: { $0.key == "anderes_hund" }),
              let meerkat = catalog.classes.firstIndex(where: { $0.key == "erdmaennchen" }) else {
            return XCTFail("Expected model classes missing")
        }
        var probabilities = [Double](repeating: 0, count: catalog.classes.count)
        probabilities[dog] = 0.49
        probabilities[elephant] = 0.48
        probabilities[meerkat] = 0.03
        XCTAssertEqual(catalog.applyPrior(probabilities, region: nil, destinationCode: "ZA"), probabilities)

        probabilities[dog] = 0.48
        probabilities[elephant] = 0.49
        XCTAssertEqual(catalog.applyPrior(probabilities, region: nil, destinationCode: "ZA"), probabilities)
    }

    func testIncompleteCountryListCannotReplaceModelWinner() {
        let catalog = SpeciesCatalog.shared
        guard let caracal = catalog.classes.firstIndex(where: { $0.key == "karakal" }),
              let leopard = catalog.classes.firstIndex(where: { $0.key == "leopard" }) else {
            return XCTFail("Expected model classes missing")
        }
        var probabilities = [Double](repeating: 0, count: catalog.classes.count)
        probabilities[caracal] = 0.51
        probabilities[leopard] = 0.45
        let adjusted = catalog.applyPrior(probabilities, region: nil, destinationCode: "ZA")
        XCTAssertGreaterThan(adjusted[caracal], adjusted[leopard])
        XCTAssertEqual(SpeciesDecision.decide(adjusted, catalog: catalog).key, "karakal")
    }

    func testCountryCannotResolveAnUncertainSpeciesGroup() throws {
        let catalog = SpeciesCatalog.shared
        for (first, second, country) in [("breitmaulnashorn", "spitzmaulnashorn", "ZA"),
                                          ("spitzmaulnashorn", "breitmaulnashorn", "KE"),
                                          ("loewe_m", "loewin", "BW")] {
            let a = try XCTUnwrap(catalog.classes.firstIndex { $0.key == first })
            let b = try XCTUnwrap(catalog.classes.firstIndex { $0.key == second })
            let other = try XCTUnwrap(catalog.classes.firstIndex { $0.key == "anderes_hund" })
            var probabilities = [Double](repeating: 0, count: catalog.classes.count)
            probabilities[a] = 0.55; probabilities[b] = 0.30; probabilities[other] = 0.15
            let before = SpeciesDecision.decide(probabilities, catalog: catalog)
            XCTAssertTrue(before.key?.hasPrefix("group:") == true)
            let adjusted = catalog.applyPrior(probabilities, region: nil, destinationCode: country)
            XCTAssertEqual(adjusted, probabilities)
            XCTAssertEqual(SpeciesDecision.decide(adjusted, catalog: catalog).key, before.key)
        }
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
