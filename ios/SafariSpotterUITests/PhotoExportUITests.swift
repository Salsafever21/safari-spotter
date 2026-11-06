import XCTest

final class PhotoExportUITests: XCTestCase {
    func testUnreadablePhotoCanBeSkippedWithConfirmationWithoutDeletingItsOriginal() {
        let app = XCUIApplication()
        app.launchEnvironment["SAFARI_SPOTTER_UI_FIXTURE"] = "photo-export-failure"
        app.launchAndCompleteTravelSetupIfNeeded()
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sichtungen")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        app.buttons["Galerie 2"].tap()
        let photo = app.buttons["gallery-photo-00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5)); photo.tap()
        let save = app.buttons["photo-save-current"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        let error = app.staticTexts["photo-export-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(error.label.contains("nicht gelesen"))
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(app.buttons["Restliche 1 Fotos erneut versuchen"].exists)
        let skip = app.buttons["photo-export-skip"].firstMatch
        skip.tap()
        XCTAssertTrue(app.buttons["Überspringen und fortsetzen"].waitForExistence(timeout: 5))
        app.buttons["Abbrechen"].tap()
        XCTAssertTrue(error.exists)
        XCTAssertFalse(save.isEnabled)
        skip.tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Beschädigtes Foto überspringen und Original behalten"; image.lifetime = .keepAlways; add(image)
        app.buttons["Überspringen und fortsetzen"].tap()
        let summary = app.descendants(matching: .any).matching(identifier: "photo-export-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 Fotos"))
        XCTAssertTrue(summary.label.contains("1 übersprungen"))
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "In Fotos sichern", "Überspringen ist kein Sicherungserfolg")
        XCTAssertTrue(app.staticTexts["Dieses Foto kann nicht angezeigt werden. Die gespeicherten Originaldaten bleiben erhalten."].exists)
    }
}
