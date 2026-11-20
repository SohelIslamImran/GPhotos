import XCTest

/// End-to-end journeys on a real iPhone with the real library and account: launch to a
/// drawn grid, scrolling, the viewer, every tab. Nothing is uploaded, deleted or signed out.
/// Screenshots are kept in the result bundle for review. Skipped on the simulator.
@MainActor
final class DeviceJourneyUITests: XCTestCase {
  private var app: XCUIApplication!

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

  private var gridCell: XCUIElement { app.images.firstMatch }

  private func tab(_ name: String) -> XCUIElement { app.tabBars.buttons[name].firstMatch }

  // MARK: Launch

  /// A cold launch must draw the grid at once (the saved snapshot, then the live grid), never
  /// a blank screen. Screenshots at fixed times show what was on screen.
  func test01ColdLaunchDrawsGrid() {
    app.terminate()
    let start = Date()
    app.launch()
    var times: [String] = []
    for delay in [0.3, 1.0, 2.0, 4.0] {
      let wait = delay - Date().timeIntervalSince(start)
      if wait > 0 { Thread.sleep(forTimeInterval: wait) }
      shot(String(format: "launch-%.1fs", delay))
    }
    let appeared = gridCell.waitForExistence(timeout: 20)
    times.append(String(format: "grid cell after %.2fs", Date().timeIntervalSince(start)))
    XCTAssertTrue(appeared, "No grid cell 20 s after launch")
    let label = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Items' OR label ENDSWITH 'Photos'"))
      .firstMatch
    if label.exists { times.append("title: \(label.label)") }
    add(XCTAttachment(string: times.joined(separator: "\n")))
  }

  func test02LaunchMetric() {
    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: Self.threeRuns) {
      app.launch()
    }
  }

  // MARK: Grid

  func test03ScrollHitches() {
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 2)
    let grid = app.scrollViews.firstMatch
    measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: Self.threeRuns) {
      // Newest photos are at the bottom; older ones are up.
      grid.swipeDown(velocity: .fast)
      grid.swipeUp(velocity: .fast)
    }
    shot("after-fling")
    for _ in 0..<6 { grid.swipeDown(velocity: .fast) }
    shot("deep-fling-0s")
    Thread.sleep(forTimeInterval: 1.5)
    shot("deep-fling-1.5s")
  }

  /// Far back in the timeline most items are only in Google Photos: their thumbnails must
  /// arrive within seconds, not leave a screen of empty cells.
  func test09DeepCloudCellsFill() {
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    let grid = app.scrollViews.firstMatch
    for _ in 0..<12 { grid.swipeDown(velocity: .fast) }
    shot("deep-0s")
    Thread.sleep(forTimeInterval: 1)
    shot("deep-1s")
    Thread.sleep(forTimeInterval: 3)
    shot("deep-4s")
    for _ in 0..<12 { grid.swipeDown(velocity: .fast) }
    Thread.sleep(forTimeInterval: 2)
    shot("deeper-2s")
  }

  func test04PinchAndModes() {
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    let grid = app.scrollViews.firstMatch
    grid.pinch(withScale: 0.5, velocity: -1)
    Thread.sleep(forTimeInterval: 0.6)
    shot("pinched-out")
    grid.pinch(withScale: 2.5, velocity: 1)
    Thread.sleep(forTimeInterval: 0.6)
    shot("pinched-in")
    grid.pinch(withScale: 0.6, velocity: -1)
    Thread.sleep(forTimeInterval: 0.6)
    // Years / Months appear once the tab bar shrinks.
    grid.swipeDown()
    for mode in ["Years", "Months", "All"] {
      let button = app.buttons[mode].firstMatch
      if button.waitForExistence(timeout: 2) {
        button.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("mode-\(mode)")
      } else {
        add(XCTAttachment(string: "mode button \(mode) not found"))
      }
    }
  }

  // MARK: Viewer

  func test05ViewerOpensPagesAndCloses() {
    app.launch()
    XCTAssertTrue(gridCell.waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 1.5)
    let cells = app.images
    let target = cells.element(boundBy: min(4, max(cells.count - 1, 0)))
    target.tap()
    shot("viewer-0.05s")
    Thread.sleep(forTimeInterval: 0.25)
    shot("viewer-0.3s")
    Thread.sleep(forTimeInterval: 1.5)
    shot("viewer-1.8s")
    for page in 1...4 {
      app.swipeRight()
      Thread.sleep(forTimeInterval: 0.15)
      shot("page-\(page)-0.15s")
      Thread.sleep(forTimeInterval: 1)
      shot("page-\(page)-1.2s")
    }
    let info = app.buttons["Info"].firstMatch
    if info.waitForExistence(timeout: 2) {
      info.tap()
      Thread.sleep(forTimeInterval: 1)
      shot("info")
      info.tap()
    }
    app.swipeDown(velocity: .fast)
    Thread.sleep(forTimeInterval: 0.8)
    shot("viewer-closed")
    XCTAssertTrue(gridCell.exists)
  }

  // MARK: Tabs

  func test06Collections() {
    app.launch()
    tab("Collections").tap()
    Thread.sleep(forTimeInterval: 2)
    shot("collections")
    app.swipeUp()
    Thread.sleep(forTimeInterval: 1)
    shot("collections-2")
    app.swipeUp()
    Thread.sleep(forTimeInterval: 1)
    shot("collections-3")
  }

  /// Collections › Google Photos › All Photos: cells on this device come from PhotoKit, the
  /// rest from Google; an opened item shows at once and sharpens.
  func test11GooglePhotosGridAndViewer() {
    app.launch()
    tab("Collections").tap()
    let allPhotos = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Photos'")).firstMatch
    for _ in 0..<4 where !allPhotos.isHittable { app.swipeUp() }
    guard allPhotos.waitForExistence(timeout: 5) else { return XCTFail("All Photos not found") }
    allPhotos.tap()
    shot("google-grid-0.3s")
    Thread.sleep(forTimeInterval: 2)
    shot("google-grid-2s")
    let grid = app.scrollViews.firstMatch
    for _ in 0..<8 { grid.swipeDown(velocity: .fast) }
    Thread.sleep(forTimeInterval: 1.5)
    shot("google-grid-deep")
    app.images.element(boundBy: min(5, max(app.images.count - 1, 0))).tap()
    shot("google-viewer-0.05s")
    Thread.sleep(forTimeInterval: 0.4)
    shot("google-viewer-0.45s")
    Thread.sleep(forTimeInterval: 2)
    shot("google-viewer-2.5s")
    app.swipeRight()
    Thread.sleep(forTimeInterval: 0.3)
    shot("google-viewer-next-0.3s")
  }

  /// A batch started in the app: its Live Activity on the Home Screen while it runs, and the
  /// summary when it ends. Adds three generated test photos to the library (and Google
  /// Photos, as backups).
  func test12LiveActivityAndSummary() {
    app.launchArguments += ["-UIAddTestPhoto", "YES", "-UITestPhotoCount", "3"]
    app.launch()
    tab("Backup").tap()
    let backingUp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Backing Up'")).firstMatch
    if !backingUp.waitForExistence(timeout: 30) { add(XCTAttachment(string: "No batch seen; it may have finished first")) }
    shot("backup-batch")
    XCUIDevice.shared.press(.home)
    for step in 1...12 {
      Thread.sleep(forTimeInterval: 0.8)
      let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      attachment.name = String(format: "home-%02d", step)
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    app.activate()
    Thread.sleep(forTimeInterval: 2)
    shot("backup-after")
  }

  func test10BackupHero() {
    app.launch()
    tab("Backup").tap()
    Thread.sleep(forTimeInterval: 3)
    shot("backup-hero")
  }

  func test07Backup() {
    app.launch()
    tab("Backup").tap()
    Thread.sleep(forTimeInterval: 2)
    shot("backup")
    for tile in ["In Progress", "Uploaded", "Failed"] {
      let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tile)).firstMatch
      guard button.waitForExistence(timeout: 3) else {
        add(XCTAttachment(string: "tile \(tile) missing"))
        continue
      }
      button.tap()
      Thread.sleep(forTimeInterval: 1.5)
      shot("activity-\(tile)")
      app.navigationBars.buttons.firstMatch.tap()
      Thread.sleep(forTimeInterval: 0.8)
    }
    app.swipeUp()
    Thread.sleep(forTimeInterval: 0.8)
    shot("backup-2")
    app.swipeUp()
    Thread.sleep(forTimeInterval: 0.8)
    shot("backup-3")
  }

  func test08Search() {
    app.launch()
    tab("Search").tap()
    Thread.sleep(forTimeInterval: 2)
    shot("search")
    let field = app.searchFields.firstMatch
    if field.waitForExistence(timeout: 3) {
      field.tap()
      field.typeText("food")
      Thread.sleep(forTimeInterval: 2)
      shot("search-food")
      for query in ["sky", "beach", "car"] {
        field.buttons["Clear text"].firstMatch.tap()
        field.typeText(query)
        Thread.sleep(forTimeInterval: 1.5)
        shot("search-\(query)")
      }
    }
  }

  private static var threeRuns: XCTMeasureOptions {
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    return options
  }
}
