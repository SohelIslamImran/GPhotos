import XCTest

/// Checks on a real iPhone for the Library, Search, Trash and account fixes. Only a photo the
/// test adds itself is deleted. Skipped on the simulator.
@MainActor
final class FixesJourneyUITests: XCTestCase {
  private var app: XCUIApplication!
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  override func setUp() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Runs on a device with a real library.")
    #else
      continueAfterFailure = true
      app = XCUIApplication()
    #endif
  }

  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func note(_ text: String) {
    let attachment = XCTAttachment(string: text)
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The notification prompt the app shows after its first backup covers the screen.
  private func acceptNotificationPrompt() {
    let allow = springboard.alerts.buttons["Allow"].firstMatch
    if allow.waitForExistence(timeout: 1) { allow.tap() }
  }

  private func tab(_ name: String) -> XCUIElement { app.tabBars.buttons[name].firstMatch }
  private var gridCell: XCUIElement { app.images.firstMatch }

  // MARK: Tab bar

  /// With the bar shrunk, Years, Months and All sit over it; a tap on them must change the
  /// view, never open the tab underneath.
  func test20ModePickerNeverOpensAnotherTab() {
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    let grid = app.scrollViews.firstMatch
    var opened: [String] = []
    for round in 0..<4 {
      // Toward older photos, then a little back, as in the report.
      grid.swipeDown()
      grid.swipeDown()
      if round % 2 == 1 { grid.swipeUp() }
      Thread.sleep(forTimeInterval: 0.6)
      for mode in ["Months", "Years", "All"] {
        let button = app.buttons[mode].firstMatch
        guard button.waitForExistence(timeout: 2), button.isHittable else {
          note("round \(round): \(mode) not shown")
          continue
        }
        button.tap()
        Thread.sleep(forTimeInterval: 0.8)
        if !tab("Library").isSelected { opened.append("round \(round) \(mode)") }
        if tab("Collections").isSelected { tab("Library").tap() }
      }
      shot("modes-round-\(round)")
    }
    XCTAssertTrue(opened.isEmpty, "Another tab opened after: \(opened)")
  }

  // MARK: Search

  /// People › a person shows that person once: Back returns to People, then to Search.
  func test21PeopleOpensEachPersonOnce() {
    app.launch()
    tab("Search").tap()
    let seeAll = app.buttons["See All"].firstMatch
    guard seeAll.waitForExistence(timeout: 30) else { return XCTFail("No People row in Search") }
    seeAll.tap()
    XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 1.5)
    shot("people")
    for attempt in 0..<3 {
      let people = app.scrollViews.firstMatch.buttons
      guard people.count > attempt else { return XCTFail("No people listed") }
      people.element(boundBy: attempt).tap()
      Thread.sleep(forTimeInterval: 1.5)
      shot("person-\(attempt)")
      XCTAssertFalse(app.navigationBars["People"].exists, "People pushed itself again (attempt \(attempt))")
      app.navigationBars.buttons.firstMatch.tap()
      XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 3), "Back didn't return to People")
      Thread.sleep(forTimeInterval: 0.8)
    }
    app.navigationBars.buttons.firstMatch.tap()
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(seeAll.waitForExistence(timeout: 3), "Back from People didn't return to Search")
    shot("search-again")
  }

  // MARK: Accounts

  func test22CopyOnlyWhileChargingSetting() {
    app.launch()
    tab("Backup").tap()
    let account = app.buttons["Account Settings"].firstMatch
    guard account.waitForExistence(timeout: 10) else { return XCTFail("No account button") }
    account.tap()
    let toggle = app.switches["Copy Only While Charging"].firstMatch
    for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Copy Only While Charging isn't shown")
    note("Copy Only While Charging: \(toggle.value ?? "?")")
    shot("accounts")
  }

  // MARK: Delete

  /// A photo added, backed up, deleted with Delete Everywhere: it leaves the Library at
  /// once (not as its Google copy), then Delete Forever removes it from Trash.
  func test23DeleteEverywhereThenDeleteForever() throws {
    let added = Date()
    app.launchArguments += ["-UIAddTestPhoto", "YES"]
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    // This run's photo, and the ones earlier runs of this test left (one still in the
    // Library, one in Trash).
    let stamps =
      [added, added.addingTimeInterval(60)].map { $0.formatted(date: .abbreviated, time: .shortened) }
      + ["7:15", "7:20", "7:21", "7:28"].map { "Nov 20, 2026 at \($0)\u{202F}PM" }
    let ours = NSCompoundPredicate(
      orPredicateWithSubpredicates: stamps.map { NSPredicate(format: "label CONTAINS %@", $0) })
    let thisRun = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", stamps[0], stamps[1])
    let backedUp = NSCompoundPredicate(andPredicateWithSubpredicates: [
      thisRun, NSPredicate(format: "label CONTAINS[c] 'backed up'"),
    ])
    /// How many items the screen says are selected.
    func selectedCount() -> Int? {
      let text = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' Selected'")).firstMatch
      guard text.waitForExistence(timeout: 2) else { return nil }
      return Int(text.label.components(separatedBy: " ").first ?? "")
    }

    // Backed up, and its Google copy synced, so the Library shows one item for both.
    let deadline = Date().addingTimeInterval(300)
    while !app.images.matching(backedUp).firstMatch.exists, Date() < deadline {
      acceptNotificationPrompt()
      Thread.sleep(forTimeInterval: 10)
      tab("Library").tap()
      Thread.sleep(forTimeInterval: 1)
    }
    acceptNotificationPrompt()
    note("labels: " + app.images.allElementsBoundByIndex.suffix(4).map(\.label).joined(separator: " | "))
    guard app.images.matching(backedUp).firstMatch.exists else {
      return XCTFail("The test photo wasn't shown as backed up within 5 minutes")
    }
    shot("backed-up")

    app.buttons["Select"].firstMatch.tap()
    Thread.sleep(forTimeInterval: 0.5)
    let candidates = app.images.matching(ours).allElementsBoundByIndex
    let picked = candidates.map(\.label)
    for cell in candidates { cell.tap() }
    Thread.sleep(forTimeInterval: 1)
    note("tapped in Library: \(picked), screen says \(selectedCount().map(String.init) ?? "?") selected")
    guard !picked.isEmpty, selectedCount() == picked.count else {
      return XCTFail("The selection isn't exactly the test photos: \(picked)")
    }
    app.buttons["Delete"].firstMatch.tap()
    let everywhere = app.buttons["Delete Everywhere"].firstMatch
    XCTAssertTrue(everywhere.waitForExistence(timeout: 5), "No Delete Everywhere for a backed-up photo")
    XCTAssertTrue(app.buttons["Delete from This Device"].exists)
    shot("delete-dialog")
    everywhere.tap()
    // iOS asks too.
    let systemDelete = springboard.alerts.buttons["Delete"].firstMatch
    if systemDelete.waitForExistence(timeout: 8) {
      systemDelete.tap()
    } else if app.alerts.buttons["Delete"].firstMatch.waitForExistence(timeout: 2) {
      app.alerts.buttons["Delete"].firstMatch.tap()
    }
    Thread.sleep(forTimeInterval: 4)
    shot("after-delete")
    XCTAssertFalse(app.images.matching(ours).firstMatch.exists, "A deleted photo is still in the Library")

    // Trash: the Google copies are there, and Delete Forever removes them.
    tab("Collections").tap()
    let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trash'")).firstMatch
    for _ in 0..<5 where !trash.isHittable { app.swipeUp() }
    guard trash.waitForExistence(timeout: 5) else { return XCTFail("No Trash in Collections") }
    note("Trash row: \(trash.label)")
    trash.tap()
    guard app.images.matching(thisRun).firstMatch.waitForExistence(timeout: 20) else {
      shot("trash")
      return XCTFail("This run's Google copy isn't in Trash")
    }
    shot("trash")
    app.buttons["Select"].firstMatch.tap()
    Thread.sleep(forTimeInterval: 0.5)
    let binnedCells = app.images.matching(ours).allElementsBoundByIndex
    let binned = binnedCells.map(\.label)
    for cell in binnedCells { cell.tap() }
    Thread.sleep(forTimeInterval: 1)
    note("tapped in Trash: \(binned), screen says \(selectedCount().map(String.init) ?? "?") selected")
    guard !binned.isEmpty, selectedCount() == binned.count else {
      return XCTFail("The Trash selection isn't exactly the test photos: \(binned)")
    }
    app.buttons["Delete Forever"].firstMatch.tap()
    let buttons = app.buttons.matching(identifier: "Delete Forever")
    guard buttons.element(boundBy: 1).waitForExistence(timeout: 5) else { return XCTFail("No Delete Forever dialog") }
    shot("delete-forever-dialog")
    // The dialog's button is the last of that name on screen.
    buttons.element(boundBy: buttons.count - 1).tap()
    Thread.sleep(forTimeInterval: 5)
    shot("trash-after")
    XCTAssertFalse(app.images.matching(ours).firstMatch.exists, "A test photo is still in Trash")
  }

  /// People and the photos of the first few, for checking the groups by eye.
  func test24PeopleGroups() {
    app.launch()
    tab("Search").tap()
    let seeAll = app.buttons["See All"].firstMatch
    guard seeAll.waitForExistence(timeout: 30) else {
      shot("search-no-people")
      return XCTFail("No People yet")
    }
    seeAll.tap()
    Thread.sleep(forTimeInterval: 2)
    shot("people-all")
    let count = min(app.scrollViews.firstMatch.buttons.count, 8)
    note("people listed: \(app.scrollViews.firstMatch.buttons.count)")
    for index in 0..<count {
      app.scrollViews.firstMatch.buttons.element(boundBy: index).tap()
      Thread.sleep(forTimeInterval: 2.5)
      shot("person-\(index)")
      app.navigationBars.buttons.firstMatch.tap()
      Thread.sleep(forTimeInterval: 1)
    }
  }
}
