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
    }

    /// Launches on the Ask page, or straight onto a tile.
    ///
    /// The tile argument is not a shortcut past a route the suite could
    /// otherwise take - there is no such route. The app has two ways between
    /// screens and XCUITest can drive neither: the radial launcher takes its
    /// touches from a window recogniser and never participates in
    /// hit-testing, and the accessible path is a set of named accessibility
    /// actions on the orb, which XCUIElement cannot invoke. The navigation-bar
    /// destinations menu that used to be the third way was removed on purpose
    /// (the launcher is THE launcher), and these tests were the only thing
    /// still driving it.
    ///
    /// What is lost is coverage of the way in; what is kept is coverage of the
    /// page. Being explicit about that is better than a test that quietly
    /// asserts an affordance the product no longer has.
    private func launch(startingOn tile: String? = nil) {
        app = XCUIApplication()
        // Starts from a clean slate with no server address, which is what
        // "demo" means now that the Demo/Live switch is gone - see AppState.
        // Without this the suite inherits whatever server the simulator was
        // last pointed at by hand, or the address baked in at build time.
        app.launchArguments = ["-ATARUUITesting"]
        if let tile {
            app.launchArguments += ["-ATARUUIStartTile", tile]
        }
        app.launch()
    }

    func testLaunchesIntoAskInDemoMode() {
        launch()
        XCTAssertTrue(app.staticTexts["Hold to ask"].waitForExistence(timeout: 8))
        // Demo state must be stated, never implied.
        XCTAssertTrue(app.staticTexts["Demo data — no backend connected."].exists)
    }

    /// The Files browser itself: rows, and a facet chip that changes them.
    ///
    /// The tile is Files now. The vault library it used to open is one source
    /// INSIDE it, reached by the "Vault records" chip - which is what the two
    /// tests below go through.
    func testFilesBrowserListsProjectFilesAndFiltersByUmbrella() {
        launch(startingOn: "documents")

        let career = app.staticTexts["Arya Sasikumar resume 2026.pdf"]
        XCTAssertTrue(career.waitForExistence(timeout: 8))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Robolabs'"))
            .firstMatch.tap()
        XCTAssertFalse(career.waitForExistence(timeout: 3),
                       "a Career file should not survive the Robolabs filter")
        XCTAssertTrue(app.staticTexts["Robolabs tournament 2025 run sheet.xlsx"]
                        .waitForExistence(timeout: 5))
    }

    /// Narrowing in words, and then the thing the NAS badge is warning about.
    ///
    /// Two assertions in one flow on purpose: the narrow field is how an away
    /// file is reached without scrolling past fifty local ones, and reaching
    /// it that way is itself the conversational path worth covering.
    func testNarrowingFindsAnAwayFileWhichSaysItIsNotOnThisHost() {
        launch(startingOn: "documents")
        let field = app.descendants(matching: .any)
            .matching(identifier: "narrow-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("videos on the nas\n")

        let away = app.staticTexts["Teleop session 041 recording.mp4"]
        XCTAssertTrue(away.waitForExistence(timeout: 8),
                      "narrowing by words did not reach the away videos")
        away.tap()
        XCTAssertTrue(app.staticTexts["Not on this host yet"]
                        .waitForExistence(timeout: 8))
    }

    private func openVaultRecords() {
        launch(startingOn: "documents")
        let chip = app.buttons["Vault records"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        chip.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 8))
    }

    func testLibraryListsDocumentsAndFiltersByCategory() {
        openVaultRecords()

        let firstDocument = app.staticTexts["System Architecture.md"]
        XCTAssertTrue(firstDocument.waitForExistence(timeout: 8))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Health'"))
            .firstMatch.tap()
        XCTAssertFalse(firstDocument.waitForExistence(timeout: 2),
                       "a work document should not survive the health filter")
    }

    func testDocumentOpensAndOffersSending() {
        openVaultRecords()
        app.staticTexts["System Architecture.md"].firstMatch.tap()

        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Preview"].exists)
        XCTAssertTrue(app.staticTexts["Vault path"].exists)
    }

    func testTypedQuestionProducesAnAnswer() {
        launch()
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

    /// Pulling a tile page down by its HANDLE closes it and puts Ask back.
    ///
    /// The drag used to work from anywhere on the page as long as the content
    /// was at its scroll top. It does not any more - see `TileDismissal` - so
    /// this drags from the handle band at the top, which is the one place it
    /// is still claimed from.
    func testATilePageIsClosedByDraggingItsHandleDown() {
        launch(startingOn: "documents")
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 8))
        // Still nothing in the navigation BAR: the X lives beside the grab bar
        // under it, which is the page's own chrome rather than the bar's.
        XCTAssertFalse(app.navigationBars["Files"].buttons["Close"].exists,
                       "a tile screen has grown a close button in its navigation bar")

        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        top.press(forDuration: 0.05, thenDragTo: bottom)

        XCTAssertTrue(app.staticTexts["Hold to ask"].waitForExistence(timeout: 5),
                      "dragging the handle down did not put it away")
    }

    /// And the X closes it too, which is the point of it being there.
    ///
    /// "Across the board in all aspects of the app, swiping down to close the
    /// window is happening too easily by accident; I just try to scroll to the
    /// top and it activates the close." Confining the drag to the handle fixed
    /// the accident; this control is what keeps the page closable without one.
    ///
    /// ON PLAN RATHER THAN FILES. This used to open Files, which is the one
    /// page that no longer has an X - he asked for it to come off, and only
    /// there. So the test moved to another page rather than being deleted:
    /// what it is actually covering is that the control still exists and
    /// still works, which is true everywhere else.
    func testATilePageIsClosedByItsCloseButton() {
        launch(startingOn: "plan")
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 8))
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "a tile screen has no explicit way to close it")
        close.tap()
        XCTAssertTrue(app.staticTexts["Hold to ask"].waitForExistence(timeout: 5),
                      "the close button did not put the page away")
    }

    /// And Files, specifically, does NOT have one.
    ///
    /// "No need for the x button in the right." The handle above the page is
    /// the whole of its visible chrome now, and the test one above is what
    /// keeps that from quietly becoming true of every other page too.
    func testTheFilesPageHasNoCloseButton() {
        launch(startingOn: "documents")
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 8))
        // Waits for the page's own chrome to exist before declaring the X
        // absent, so this cannot pass merely by looking too early.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "narrow-field").firstMatch
            .waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Close"].exists,
                       "the Files page has grown its X back")
    }

    /// Dragging the CONTENT down no longer closes the page.
    ///
    /// This is the regression test for the report itself: a flick downward in
    /// the middle of a page - which is what scrolling back to the top is -
    /// must leave the page exactly where it was.
    func testDraggingTheContentDownDoesNotClose() {
        launch(startingOn: "documents")
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 8))

        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        middle.press(forDuration: 0.05, thenDragTo: lower)

        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3),
                      "a downward drag on the content closed the page")
    }
}
