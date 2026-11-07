import XCTest

final class SightingHistoryUITests: XCTestCase {
    func testCountingStopsAtOneAndDeletionRequiresConfirmationWithoutDeletingPhotos() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "drive-history"
        app.launchAndCompleteTravelSetupIfNeeded()
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sichtungen")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let count = app.steppers["sighting-count-Leopard"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), app.debugDescription)
        let decrease = count.buttons.element(boundBy: 0)
        let increase = count.buttons.element(boundBy: 1)
        XCTAssertEqual(count.value as? String, "1")
        decrease.tap()
        XCTAssertEqual(count.value as? String, "1", "Minus bei eins darf weder löschen noch die Anzahl ändern")
        increase.tap()
        XCTAssertEqual(count.value as? String, "2")
        decrease.tap()
        XCTAssertEqual(count.value as? String, "1")
        XCTAssertTrue(app.buttons["Leopard"].exists)

        app.buttons["Leopard"].swipeLeft()
        app.buttons["sighting-delete-Leopard"].tap()
        XCTAssertTrue(app.buttons["Sichtung löschen"].waitForExistence(timeout: 5))
        app.buttons["Abbrechen"].tap()
        XCTAssertTrue(app.buttons["Leopard"].exists)
        app.buttons["Leopard"].swipeLeft()
        app.buttons["sighting-delete-Leopard"].tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Sichtung ausdrücklich löschen, Fotos behalten"; image.lifetime = .keepAlways; add(image)
        app.buttons["Sichtung löschen"].tap()
        XCTAssertFalse(app.buttons["Leopard"].exists)
        XCTAssertTrue(app.buttons["Galerie 2"].exists, "Die Fotos bleiben nach dem Löschen der Sichtung erhalten")
    }

    func testDateAndSpeciesFiltersCanAlwaysReturnToAllSavedSightings() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "drive-history"
        app.launchAndCompleteTravelSetupIfNeeded()
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sichtungen")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let summary = app.staticTexts["sighting-filter-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2 von 2"))
        app.buttons["Heute"].tap()
        XCTAssertTrue(summary.label.contains("0 von 2"))
        app.buttons["sighting-filter-reset"].tap()
        XCTAssertTrue(summary.label.contains("2 von 2"))
        let search = app.textFields["sighting-species-search"]
        search.tap(); search.typeText("Elefant\n")
        XCTAssertTrue(summary.label.contains("1 von 2"))
        XCTAssertTrue(app.buttons["Elefant"].exists)
        XCTAssertFalse(app.buttons["Leopard"].exists)
        app.buttons["Zählung"].tap()
        XCTAssertTrue(app.buttons["Auswahl als CSV teilen"].exists)
        app.buttons["sighting-filter-reset"].tap()
        app.buttons["Liste"].tap()
        XCTAssertTrue(app.buttons["Elefant"].exists)
        XCTAssertTrue(app.buttons["Leopard"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Sichtungen über mehrere Tage"; image.lifetime = .keepAlways; add(image)
    }
}
