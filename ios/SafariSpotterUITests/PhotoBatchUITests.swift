import XCTest

final class PhotoBatchUITests: XCTestCase {
    func testTwoPhotosAdvanceAfterFirstSave() {
        let app = XCUIApplication()
        app.launch()
        let analyze = app.buttons["Bilder analysieren"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 10))
        analyze.tap()
        let pick = app.buttons["Bilder auswählen"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertGreaterThanOrEqual(photos.count, 2)
        photos.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        photos.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.navigationBars["Fotos"].buttons["Fertig"]
        XCTAssertTrue(done.isEnabled, app.debugDescription)
        done.tap()

        XCTAssertTrue(app.staticTexts["Bild 1 von 2"].waitForExistence(timeout: 15))
        let save = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                                     "Als Sichtung speichern", "Foto behalten")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 60), app.debugDescription)
        save.tap()
        XCTAssertTrue(app.staticTexts["Bild 2 von 2"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(save.waitForExistence(timeout: 60), app.debugDescription)
        save.tap()
        XCTAssertTrue(analyze.waitForExistence(timeout: 10) && analyze.isHittable)
    }
}
