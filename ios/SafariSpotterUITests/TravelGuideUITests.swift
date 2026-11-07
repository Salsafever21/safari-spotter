import XCTest

final class TravelGuideUITests: XCTestCase {
    func testCountryGuideShowsWaterAnimalsAfterOnboarding() {
        let app = XCUIApplication()
        app.launchAndCompleteTravelSetupIfNeeded()
        let guide = app.buttons["Tierführer für das Reiseziel"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        guide.tap()
        XCTAssertTrue(app.navigationBars["Tierführer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["travel-guide-country"].label.contains("Südafrika"))
        app.buttons["Wasser"].tap()
        XCTAssertTrue(app.staticTexts["Flusspferd"].waitForExistence(timeout: 5))
    }
}
