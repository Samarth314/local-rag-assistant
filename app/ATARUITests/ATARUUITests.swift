import XCTest

/// Smoke tests for the two things the app does.
///
/// Deliberately shallow: they prove the app launches, both tabs render real
/// content, and the two flows the product exists for are reachable. Anything
/// finer-grained belongs in the unit tests, which don't need a simulator.
final class ATARUUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Starts from a clean slate in Demo mode. Without this the suite
        // inherits whatever server the simulator was last pointed at by hand.
        app.launchArguments = ["-ATARUUITesting"]
        app.launch()
    }

    func testLaunchesIntoAskInDemoMode() {
        XCTAssertTrue(app.staticTexts["Hold to ask"].waitForExistence(timeout: 8))
        // Demo state must be stated, never implied.
        XCTAssertTrue(app.staticTexts["Demo data — no backend connected."].exists)
    }

    func testLibraryListsDocumentsAndFiltersByCategory() {
        app.tabBars.buttons["Library"].tap()

        let firstDocument = app.staticTexts["System Architecture.md"]
        XCTAssertTrue(firstDocument.waitForExistence(timeout: 8))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Health'"))
            .firstMatch.tap()
        XCTAssertFalse(firstDocument.waitForExistence(timeout: 2),
                       "a work document should not survive the health filter")
    }

    func testDocumentOpensAndOffersSending() {
        app.tabBars.buttons["Library"].tap()
        app.staticTexts["System Architecture.md"].firstMatch.tap()

        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Preview"].exists)
        XCTAssertTrue(app.staticTexts["Vault path"].exists)
    }

    func testTypedQuestionProducesAnAnswer() {
        // The field is inline on the Ask screen now, not behind a sheet —
        // there is no "Type instead" button to open first.
        //
        // Queried by identifier across any element type: a multi-line
        // TextField surfaces as a textView on some iOS versions and a
        // textField on others, and the test should not care which.
        // The confirm button carries an identifier too, because "Ask" is also
        // the tab label and the navigation title.
        let field = app.descendants(matching: .any)
            .matching(identifier: "question-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("what is the backup policy")
        app.buttons["submit-question"].tap()

        // The answer text, not just a spinner.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Snapshots'")
        ).firstMatch.waitForExistence(timeout: 15))
    }
}
