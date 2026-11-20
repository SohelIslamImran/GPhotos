import XCTest

/// Drives every user-facing control on iOS. Actions that would upload to, or sign out of,
/// the real Google account are opened and then cancelled, never confirmed.
@MainActor
final class GPhotosSyncUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  /// Library is the first tab; these tests start on Backup.
  private func launch(screen: String? = "backup") {
    if let screen { app.launchArguments += ["-UIScreen", screen] }
    app.launch()
    // Photos permission may be requested on first launch.
    addUIInterruptionMonitor(withDescription: "Photos access") { alert in
      for label in ["Allow Full Access", "Allow Access to All Photos", "OK"] where alert.buttons[label].exists {
        // iOS 27's prompt can list the same button more than once.
        alert.buttons.matching(identifier: label).firstMatch.tap()
        return true
      }
      return false
    }
  }

  private func element(_ query: XCUIElementQuery, _ label: String) -> XCUIElement {
    query.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
    var swipes = 0
    while !element.isHittable, swipes < maxSwipes {
      app.swipeUp()
      swipes += 1
    }
  }

  // MARK: Dashboard

  func testDashboardShowsStatusTilesAndEveryOption() {
    launch()
    XCTAssertTrue(app.navigationBars["GPhotos"].waitForExistence(timeout: 10))
    for tile in ["To Back Up", "Uploaded", "Failed"] {
      XCTAssertTrue(element(app.buttons, tile).exists, "missing tile \(tile)")
    }
    XCTAssertTrue(app.buttons["See all activity"].exists)
    let options = [
      "Auto-Sync", "Pair Live Photos", "Date from Filename", "Concurrent Uploads", "Mirror Photos Albums",
      "Delete After Backup", "Only When Low on Space", "Clean Up Now",
    ]
    for option in options {
      let text = app.staticTexts[option]
      scrollTo(text)
      XCTAssertTrue(text.exists, "missing option \(option)")
    }
  }

  func testTogglesRoundTrip() {
    launch()
    for name in ["Pair Live Photos", "Date from Filename"] {
      let toggle = app.switches[name]
      scrollTo(toggle)
      XCTAssertTrue(toggle.waitForExistence(timeout: 5), "missing toggle \(name)")
      let before = toggle.value as? String
      // iOS 26 switches ignore zero-length synthetic taps (Settings.app's do too), and on
      // iOS 27 the row's label doesn't flip it: the press lands on the switch itself.
      let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
      knob.press(forDuration: 0.2)
      XCTAssertNotEqual(toggle.value as? String, before, "\(name) did not change")
      knob.press(forDuration: 0.2)
      XCTAssertEqual(toggle.value as? String, before, "\(name) did not restore")
    }
  }

  func testConcurrentUploadsStepper() {
    launch()
    let increment =
      app.buttons["Concurrent Uploads-Increment"].exists
      ? app.buttons["Concurrent Uploads-Increment"] : app.steppers.buttons["Increment"].firstMatch
    let decrement =
      app.buttons["Concurrent Uploads-Decrement"].exists
      ? app.buttons["Concurrent Uploads-Decrement"] : app.steppers.buttons["Decrement"].firstMatch
    scrollTo(increment)
    XCTAssertTrue(increment.waitForExistence(timeout: 5))
    // Read the value so the test proves a real round trip.
    let value = app.staticTexts["ConcurrentUploadsValue"]
    XCTAssertTrue(value.exists)
    let before = value.label
    // Like switches, the simulator can drop zero-duration taps on stepper buttons.
    increment.press(forDuration: 0.15)
    XCTAssertNotEqual(value.label, before, "increment didn't register")
    decrement.press(forDuration: 0.15)
    XCTAssertEqual(value.label, before, "stepper didn't return to its value")
  }

  func testDeleteAfterBackupMenuAndCleanUpGuard() {
    launch()
    // A menu-style Picker shows its current value as the button title.
    let picker = app.buttons.matching(NSPredicate(format: "label == 'Delete After Backup' OR value == 'Never'")).firstMatch
    scrollTo(picker)
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    picker.tap()
    let option = app.buttons["24 hours"].exists ? app.buttons["24 hours"] : app.staticTexts["24 hours"]
    XCTAssertTrue(option.waitForExistence(timeout: 3), "delay options did not appear")
    let never = app.buttons["Never"].exists ? app.buttons["Never"] : app.staticTexts["Never"]
    never.tap()
    // With "Never", nothing is eligible, so Clean Up must be unavailable.
    let cleanUp = element(app.buttons, "Clean Up")
    scrollTo(cleanUp)
    XCTAssertFalse(cleanUp.isEnabled)
    XCTAssertFalse(app.switches["Only When Low on Space"].isEnabled)
  }

  // MARK: Activity

  func testActivityFiltersSearchAndBack() {
    launch()
    app.buttons["See all activity"].tap()
    XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
    for filter in ["All", "To Back Up", "Uploaded", "Failed"] {
      let tab = element(app.buttons, filter)
      XCTAssertTrue(tab.waitForExistence(timeout: 3), "missing filter \(filter)")
      tab.tap()
      XCTAssertTrue(tab.isSelected, "\(filter) not selected")
    }
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.tap()
    search.typeText("zz-no-such-file-zz")
    let noResults = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch
    XCTAssertTrue(noResults.waitForExistence(timeout: 3))
    // Clear with the field's own clear button, found by its label rather than position.
    let clear = search.buttons.matching(NSPredicate(format: "label ==[c] 'Clear text'")).firstMatch
    (clear.exists ? clear : search.buttons.firstMatch).tap()
    XCTAssertFalse(noResults.waitForExistence(timeout: 2))
    // End the search session first; while it's active the back button is not hittable.
    let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'close'")).firstMatch
    if close.exists { close.tap() }
    app.navigationBars["Activity"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["GPhotos"].waitForExistence(timeout: 5))
  }

  func testTilesOpenFilteredActivity() {
    launch()
    for (tile, filter) in [("Uploaded", "Uploaded"), ("Failed", "Failed"), ("To Back Up", "To Back Up")] {
      element(app.buttons, tile).tap()
      XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
      XCTAssertTrue(element(app.buttons, filter).isSelected, "\(tile) tile did not select \(filter)")
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
  }

  // MARK: Sheets

  func testUploadSourceSheetOpensAndCloses() {
    launch()
    app.buttons["Upload Photos or Files"].tap()
    let title = app.staticTexts["Upload Media"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Photo Library"].exists)
    XCTAssertTrue(app.staticTexts["Files"].exists)
    app.buttons["Close"].tap()
    XCTAssertTrue(title.waitForNonExistence(timeout: 3))
  }

  func testPhotoPickerCanBeCancelled() {
    launch()
    app.buttons["Upload Photos or Files"].tap()
    let source = app.staticTexts["Photo Library"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.tap()
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Upload Media"].waitForExistence(timeout: 5))
  }

  func testFilesPickerCanBeCancelled() {
    launch()
    app.buttons["Upload Photos or Files"].tap()
    let source = app.staticTexts["Files"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.tap()
    // The Files picker runs out of process and is slow on a freshly booted simulator.
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 20))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Upload Media"].waitForExistence(timeout: 5))
  }

  func testAccountSheetAndCancelledSignOut() throws {
    launch()
    let account = app.buttons["Account Settings"]
    guard account.waitForExistence(timeout: 5) else {
      throw XCTSkip("Not signed in on this simulator")
    }
    account.tap()
    XCTAssertTrue(app.buttons["Sign Out"].waitForExistence(timeout: 5))
    app.buttons["Sign Out"].tap()
    // The confirmation must appear; cancel it so the account is kept.
    let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign Out'")).element(boundBy: 1)
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.tap() }
    XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3))
    app.buttons["Close"].tap()
  }

  func testSignInSheetMethodsAndCancel() {
    launch(screen: "signIn")
    XCTAssertTrue(app.staticTexts["Connect Google Photos"].waitForExistence(timeout: 5))
    let token = element(app.buttons, "Paste a Token")
    token.tap()
    XCTAssertTrue(app.staticTexts["Paste it here."].waitForExistence(timeout: 3), "sheet closed on method switch")
    let connect = element(app.buttons, "Connect")
    XCTAssertFalse(connect.isEnabled, "Connect must need a token")
    let field = app.secureTextFields["Google token"]
    field.tap()
    field.typeText("oauth2_4/example")
    XCTAssertTrue(connect.isEnabled)
    app.buttons["Where do I find it?"].tap()
    element(app.buttons, "Sign in with Google").tap()
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertFalse(app.staticTexts["Connect Google Photos"].waitForExistence(timeout: 3))
  }

  func testDeepLinkOpensFailedActivity() {
    launch(screen: "failed")
    XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
    XCTAssertTrue(element(app.buttons, "Failed").isSelected)
  }
}
