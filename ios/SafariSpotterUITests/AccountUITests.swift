import XCTest

final class AccountUITests: XCTestCase {
    func testAccountIsOptionalAndExistingSpottingsAreAvailable() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "drive-history"
        app.launchAndCompleteTravelSetupIfNeeded()

        let settings = app.buttons["Einstellungen"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let account = app.buttons["open-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["account-sign-in"].firstMatch.exists)

        app.navigationBars["Konto"].buttons.firstMatch.tap()
        app.buttons["close-settings"].tap()
        let sightings = app.buttons["Sichtungen"]
        XCTAssertTrue(sightings.waitForExistence(timeout: 5))
        sightings.tap()
        let spottings = app.buttons["open-spottings"]
        XCTAssertTrue(spottings.waitForExistence(timeout: 5))
        spottings.tap()
        let progress = app.staticTexts["spottings-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "2 Arten entdeckt")
    }
}
