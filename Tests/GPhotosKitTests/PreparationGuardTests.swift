import Foundation
import Testing

@testable import GPhotosKit

@Suite("Preparation guard")
struct PreparationGuardTests {
  private func freshDefaults() -> UserDefaults {
    let name = "PreparationGuardTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("An item that ends the process twice is skipped for a day, then tried again")
  func skipsAfterTwoInterruptions() {
    let defaults = freshDefaults()
    let start = Date()
    PreparationGuard(defaults: defaults, now: start).begin("a")
    // First relaunch: one interruption, still tried.
    let second = PreparationGuard(defaults: defaults, now: start)
    #expect(!second.isSkipped("a", now: start))
    second.begin("a")
    // Second relaunch: skipped.
    let third = PreparationGuard(defaults: defaults, now: start)
    #expect(third.isSkipped("a", now: start.addingTimeInterval(60)))
    #expect(!third.isSkipped("a", now: start.addingTimeInterval(PreparationGuard.skipInterval + 1)))
  }

  @Test("Retrying a skipped item ends its skip at once")
  func forgivingEndsSkip() {
    let defaults = freshDefaults()
    let start = Date()
    PreparationGuard(defaults: defaults, now: start).begin("a")
    PreparationGuard(defaults: defaults, now: start).begin("a")
    let relaunched = PreparationGuard(defaults: defaults, now: start)
    #expect(relaunched.isSkipped("a", now: start))
    relaunched.forgive("a")
    #expect(!relaunched.isSkipped("a", now: start))
    #expect(!relaunched.isSuspect("a"))
  }

  @Test("An item that comes back clears its interruptions")
  func returningClears() {
    let defaults = freshDefaults()
    PreparationGuard(defaults: defaults).begin("a")
    let relaunched = PreparationGuard(defaults: defaults)
    relaunched.begin("a")
    relaunched.end("a")
    PreparationGuard(defaults: defaults).begin("a")
    #expect(!PreparationGuard(defaults: defaults).isSkipped("a"))
  }

  @Test("Items that finished leave no marker behind")
  func finishedLeavesNothing() {
    let defaults = freshDefaults()
    let guardian = PreparationGuard(defaults: defaults)
    guardian.begin("a")
    guardian.end("a")
    #expect(!PreparationGuard(defaults: defaults).isSkipped("a"))
    #expect(defaults.stringArray(forKey: "preparationGuard.markers")?.isEmpty ?? true)
  }

  @Test("A quit the system announces does not count as an interruption")
  func cleanExitForgets() {
    let defaults = freshDefaults()
    let guardian = PreparationGuard(defaults: defaults)
    guardian.begin("a")
    guardian.forgetInFlight()
    PreparationGuard(defaults: defaults).begin("a")
    #expect(!PreparationGuard(defaults: defaults).isSkipped("a"))
  }

  @Test("Ending the process while the app is off screen does not count")
  func offScreenDoesNotCount() {
    let defaults = freshDefaults()
    let guardian = PreparationGuard(defaults: defaults)
    guardian.setRecordsMarkers(false)
    guardian.begin("a")
    #expect(!PreparationGuard(defaults: defaults).isSuspect("a"))

    // Back on screen, the item still in flight counts again.
    let relaunched = PreparationGuard(defaults: defaults)
    relaunched.setRecordsMarkers(false)
    relaunched.begin("b")
    relaunched.setRecordsMarkers(true)
    #expect(PreparationGuard(defaults: defaults).isSuspect("b"))
  }

  @Test("An item in flight when the process died is a suspect until it finishes")
  func suspects() {
    let defaults = freshDefaults()
    let guardian = PreparationGuard(defaults: defaults)
    guardian.begin("a")
    #expect(!guardian.isSuspect("a"))
    let relaunched = PreparationGuard(defaults: defaults)
    #expect(relaunched.isSuspect("a"))
    #expect(!relaunched.isSuspect("b"))
    relaunched.begin("a")
    relaunched.end("a")
    #expect(!relaunched.isSuspect("a"))
  }
}
