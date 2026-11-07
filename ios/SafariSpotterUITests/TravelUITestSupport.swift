import XCTest

extension XCUIApplication {
    func launchAndCompleteTravelSetupIfNeeded() {
        launch()
        let start = buttons["travel-start"]
        guard start.waitForExistence(timeout: 5) else { return }
        buttons["travel-origin"].tap()
        let search = searchFields["Land suchen"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Schweiz")
        let origin = buttons["travel-country-CH"].firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 10), debugDescription)
        origin.tap()
        buttons["travel-destination"].tap()
        let destination = buttons["travel-country-ZA"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10), debugDescription)
        destination.tap()
        XCTAssertTrue(start.isEnabled)
        start.tap()
    }
}
