import XCTest

final class BackupUITests: XCTestCase {
    func testLocalBackupCanBeRestoredAndRemainsAvailable() {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Einstellungen"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let create = app.buttons["Passwortgeschützte Sicherung erstellen"]
        for _ in 0..<4 where !create.exists { app.swipeUp() }
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        create.tap()
        let password = "Safari-Test-Backup-2026"
        let fields = app.secureTextFields
        XCTAssertEqual(fields.count, 2)
        fields["Passwort"].tap()
        fields["Passwort"].typeText(password)
        fields["Passwort wiederholen"].tap()
        fields["Passwort wiederholen"].typeText(password)
        app.buttons["Erstellen"].tap()

        let restore = app.buttons["Wiederherstellen"].firstMatch
        for _ in 0..<4 where !restore.exists { app.swipeUp() }
        XCTAssertTrue(restore.waitForExistence(timeout: 40), app.debugDescription)
        restore.tap()
        let unlock = app.secureTextFields["Passwort"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        unlock.typeText(password)
        app.buttons["Importieren"].tap()

        let success = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Wiederhergestellt:")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(restore.exists, "Die lokale Sicherungsdatei muss nach dem Wiederherstellen verfügbar bleiben.")
    }
}
