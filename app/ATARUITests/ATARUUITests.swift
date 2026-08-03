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
        openLibrary()

        let firstDocument = app.staticTexts["System Architecture.md"]
        XCTAssertTrue(firstDocument.waitForExistence(timeout: 8))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Health'"))
            .firstMatch.tap()
        XCTAssertFalse(firstDocument.waitForExistence(timeout: 2),
                       "a work document should not survive the health filter")
    }

    func testDocumentOpensAndOffersSending() {
        openLibrary()
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
        // A coordinate tap, not `field.tap()`.
        //
        // `tap()` resolves the element and synthesises against it, and against
        // this one it never lands focus: a vertical-axis TextField reports a
        // 19pt strip in the middle of a 52pt capsule. A coordinate tap is what
        // a thumb does — a touch at a point — which the capsule's own tap
        // handler turns into focus.
        //
        // `typeText` is the assertion that focus really happened: it fails
        // with "Neither element nor any descendant has keyboard focus" if it
        // did not. Checking `app.keyboards` instead would be wrong — a
        // simulator with a hardware keyboard attached focuses the field and
        // shows no software keyboard at all.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        field.typeText("what is the backup policy")
        app.buttons["submit-question"].tap()

        // The answer text, not just a spinner.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Snapshots'")
        ).firstMatch.waitForExistence(timeout: 15))
    }

    /// Navigates to the document library.
    ///
    /// Through the navigation bar's destinations menu, not the radial
    /// launcher. The launcher takes its touches from a recogniser on the
    /// window and never participates in hit-testing, so there is nothing there
    /// for XCUITest to tap — which is the same reason VoiceOver and Switch
    /// Control cannot use it, and the reason this menu exists.
    ///
    /// That makes this test the guard on the accessible route: if the menu is
    /// ever dropped as redundant, this fails rather than the app silently
    /// becoming unnavigable for anyone who cannot press-and-sweep.
    private func openLibrary() {
        app.buttons["open-menu"].tap()
        let item = app.buttons["Docs"]
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "the destinations menu did not open")
        item.tap()
    }
}
