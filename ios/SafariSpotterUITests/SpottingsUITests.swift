import XCTest

final class SpottingsUITests: XCTestCase {
    func testExistingSightingsAppearInAlbumEvenWhenHistoryShowsToday() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "drive-history"
        app.launchAndCompleteTravelSetupIfNeeded()
        let open = app.buttons["Sichtungen"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        app.buttons["Heute"].tap()
        XCTAssertTrue(app.staticTexts["sighting-filter-summary"].label.contains("0 von 2"))
        app.buttons["open-spottings"].tap()
        let progress = app.staticTexts["spottings-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(progress.label, "2 Arten entdeckt")

        app.buttons["Luft"].tap()
        let elephant = app.buttons["spottings-species-Loxodonta africana"]
        XCTAssertFalse(elephant.exists)
        app.buttons["Boden"].tap()
        XCTAssertTrue(elephant.exists)
        capture("Spottings Sammelalbum", in: app)
        elephant.tap()
        let history = app.buttons["spottings-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["14.11.2023"].exists)
        capture("Spottings Artenkarte", in: app)
        history.tap()
        XCTAssertTrue(app.staticTexts["spottings-active-species"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Elefant"].exists)
        XCTAssertFalse(app.buttons["Leopard"].exists)
        app.buttons["sighting-filter-reset"].tap()
        XCTAssertTrue(app.buttons["Leopard"].exists)

        app.buttons["Galerie 2"].tap()
        XCTAssertTrue(app.staticTexts["Galerie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Alle in Fotos sichern"].exists)
        capture("Feldjournal Galerie", in: app)
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
