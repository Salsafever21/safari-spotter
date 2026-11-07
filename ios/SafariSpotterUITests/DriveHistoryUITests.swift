import XCTest

final class DriveHistoryUITests: XCTestCase {
    func testEachSavedDriveShowsOnlyItsOwnAnimalsAndPhotos() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "drive-history"
        app.launchAndCompleteTravelSetupIfNeeded()
        let sightings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sichtungen")).firstMatch
        XCTAssertTrue(sightings.waitForExistence(timeout: 10))
        sightings.tap()
        app.buttons["Karte"].tap()
        let first = app.buttons["saved-drive-00000000-0000-0000-0000-000000000001"]
        for _ in 0..<3 where !first.exists { app.swipeUp() }
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        first.tap()
        XCTAssertTrue(app.navigationBars["Game Drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 Art · 1 Foto aus diesem Zeitraum"].exists)
        for _ in 0..<3 where !app.staticTexts["Sichtungen dieser Fahrt"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(identifier: "Elefant").firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(identifier: "Leopard").firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Gespeicherter Game Drive"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.navigationBars["Game Drive"].buttons.element(boundBy: 0).tap()
        let second = app.buttons["saved-drive-00000000-0000-0000-0000-000000000002"]
        for _ in 0..<3 where !second.exists { app.swipeUp() }
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        for _ in 0..<3 where !app.staticTexts["Sichtungen dieser Fahrt"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(identifier: "Leopard").firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(identifier: "Elefant").firstMatch.exists)
    }
}
