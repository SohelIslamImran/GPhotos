import Foundation
import Testing

@testable import GPhotosKit

@Suite("Shared UI logic")
struct UILogicTests {
  private func inputs(_ configure: (inout BackupStatus.Inputs) -> Void) -> BackupStatus.Inputs {
    var inputs = BackupStatus.Inputs()
    inputs.isSignedIn = true
    configure(&inputs)
    return inputs
  }

  @Test("A keychain failure outranks signed-out, since signing in again would fail the same way")
  func credentialErrorOutranksSignedOut() {
    let status = BackupStatus(
      inputs {
        $0.isSignedIn = false
        $0.credentialError = "Keychain locked"
      })
    #expect(status == .credentialsUnavailable("Keychain locked"))
  }

  @Test("Startup reads as one scan, without flashing signed-out before the account loads")
  func startupReadsAsScanning() {
    #expect(
      BackupStatus(
        inputs {
          $0.isStarting = true
          $0.isSignedIn = false
        }) == .scanning(.photoLibrary))
    #expect(
      BackupStatus(
        inputs {
          $0.isStarting = true
          $0.source = .folders
        }) == .scanning(.folders))
    #expect(
      BackupStatus(
        inputs {
          $0.isStarting = true
          $0.isRunning = true
        }) == .syncing(itemCount: 0))
    #expect(
      BackupStatus(
        inputs {
          $0.isStarting = true
          $0.credentialError = "Locked"
        }) == .credentialsUnavailable("Locked"))
  }

  @Test("An active transfer outranks a missing source and failures")
  func runningOutranksConfigurationProblems() {
    let status = BackupStatus(
      inputs {
        $0.isRunning = true
        $0.uploadingCount = 1
        $0.queuedCount = 2
        $0.failedCount = 3
        $0.sourceIssue = .noFolders
      })
    #expect(status == .syncing(itemCount: 3))
  }

  @Test("Stopping and paused are distinguished while running")
  func stoppingAndPaused() {
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isStopping = true
          $0.isPaused = true
        }) == .stopping)
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isPaused = true
        }) == .paused)
  }

  @Test("A running backup held off a metered network waits for Wi‑Fi")
  func waitingForNetwork() {
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isWaitingForNetwork = true
          $0.queuedCount = 2
        })
        == .waitingForNetwork)
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isWaitingForNetwork = true
          $0.isPaused = true
        }) == .paused)
    #expect(
      BackupStatus(
        inputs {
          $0.isWaitingForNetwork = true
          $0.queuedCount = 2
        }) == .waitingForNetwork)
  }

  @Test("Queued items distinguish a lost connection from an extension handoff")
  func queuedWaitReasons() {
    #expect(
      BackupStatus(
        inputs {
          $0.queuedCount = 5
          $0.isOffline = true
          $0.isWaitingForBackgroundBackup = true
        }) == .offline)
    #expect(
      BackupStatus(
        inputs {
          $0.queuedCount = 5
          $0.isWaitingForBackgroundBackup = true
        }) == .waitingForBackgroundBackup)
  }

  @Test("A running backup Google asked to slow down says so, below pause and Wi‑Fi")
  func rateLimited() {
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isRateLimited = true
        }) == .rateLimited)
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isRateLimited = true
          $0.isPaused = true
        }) == .paused)
    #expect(
      BackupStatus(
        inputs {
          $0.isRunning = true
          $0.isRateLimited = true
          $0.isWaitingForNetwork = true
        })
        == .waitingForNetwork)
    #expect(
      BackupStatus(
        inputs {
          $0.isRateLimited = true
          $0.queuedCount = 2
        }) == .waiting(count: 2))
  }

  @Test("Metered uploads are allowed by default and survive a round trip")
  func meteredNetworkSetting() throws {
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).uploadsOnMeteredNetworks)
    let changed = AppSettings(uploadsOnMeteredNetworks: false)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)) == changed)
  }

  @Test("Limited Photos access does not hide failures or pending work")
  func limitedAccessIsLowPriority() {
    let failed = BackupStatus(
      inputs {
        $0.sourceIssue = .limitedPhotosAccess
        $0.failedCount = 2
      })
    #expect(failed == .failed(count: 2))
    let idle = BackupStatus(inputs { $0.sourceIssue = .limitedPhotosAccess })
    #expect(idle == .needsSource(.limitedPhotosAccess))
  }

  @Test("A blocking source issue outranks failures")
  func sourceIssueOutranksFailures() {
    let status = BackupStatus(
      inputs {
        $0.sourceIssue = .foldersBlocked(count: 2)
        $0.failedCount = 1
      })
    #expect(status == .needsSource(.foldersBlocked(count: 2)))
  }

  @Test("Idle states fall through in order: pending, albums, auto-sync off, stopped, up to date")
  func idleOrdering() {
    #expect(
      BackupStatus(
        inputs {
          $0.queuedCount = 4
          $0.autoSyncEnabled = false
        }) == .waiting(count: 4))
    #expect(
      BackupStatus(
        inputs {
          $0.albumWarning = "x"
          $0.autoSyncEnabled = false
        }) == .albumsNeedAttention("x"))
    #expect(
      BackupStatus(
        inputs {
          $0.autoSyncEnabled = false
          $0.isStoppedForSession = true
        }) == .autoSyncOff)
    #expect(BackupStatus(inputs { $0.isStoppedForSession = true }) == .stopped)
    #expect(BackupStatus(inputs { _ in }) == .upToDate)
  }

  @Test("Every status has copy and a symbol")
  func everyStatusIsDescribed() {
    let all: [BackupStatus] = [
      .credentialsUnavailable("e"), .signedOut, .importFailed("e"), .stopping, .paused, .waitingForNetwork,
      .rateLimited, .syncing(itemCount: 2),
      .scanning(.folders), .scanning(.photoLibrary), .needsSource(.photosAccessNeeded(canPrompt: true)),
      .needsSource(.photosAccessNeeded(canPrompt: false)), .needsSource(.limitedPhotosAccess),
      .needsSource(.noFolders), .needsSource(.foldersBlocked(count: 1)), .failed(count: 1), .waiting(count: 1),
      .albumsNeedAttention("a"), .autoSyncOff, .stopped, .cleanedUp("c"), .upToDate,
    ]
    for status in all {
      #expect(!status.title.isEmpty)
      #expect(!status.subtitle.isEmpty)
      #expect(!status.symbol.isEmpty)
      #expect(!status.menuBarSymbol.isEmpty)
    }
  }

  @Test("kind ignores payloads, so view identity is stable across counts and messages")
  func statusKindIsStable() {
    #expect(BackupStatus.syncing(itemCount: 1).kind == BackupStatus.syncing(itemCount: 9).kind)
    #expect(BackupStatus.failed(count: 1).kind == BackupStatus.failed(count: 4).kind)
    #expect(BackupStatus.cleanedUp("a").kind == BackupStatus.cleanedUp("b").kind)
    #expect(BackupStatus.needsSource(.foldersBlocked(count: 1)).kind == "needsSource.foldersBlocked")
    #expect(BackupStatus.syncing(itemCount: 1).kind != BackupStatus.failed(count: 1).kind)
    #expect(BackupStatus.needsSource(.noFolders).kind != BackupStatus.needsSource(.limitedPhotosAccess).kind)
  }

  @Test("Renamed titles")
  func renamedTitles() {
    #expect(BackupStatus.autoSyncOff.title == "Auto-Sync Off")
    #expect(BackupStatus.cleanedUp("c").title == "Cleaned Up")
  }

  private func record(_ status: TransferStatus, name: String = "IMG_0001.HEIC", error: String? = nil) -> TransferRecord {
    TransferRecord(
      id: UUID().uuidString, filename: name, mediaType: "photo", status: status, lastError: error,
      sourcePath: "/Users/me/Pictures/\(name)")
  }

  @Test("Each filter selects its status, and removed originals count as uploaded")
  func filterMembership() {
    let records = [record(.pending), record(.sending), record(.sent), record(.deleted), record(.failed)]
    #expect(ActivityFilter.all.apply(to: records, query: "").count == 5)
    #expect(ActivityFilter.pending.apply(to: records, query: "").map(\.status) == [.pending, .sending])
    #expect(ActivityFilter.uploaded.apply(to: records, query: "").map(\.status) == [.sent, .deleted])
    #expect(ActivityFilter.failed.apply(to: records, query: "").map(\.status) == [.failed])
  }

  @Test("Search matches name, path and error, ignoring case and surrounding spaces")
  func filterSearch() {
    let records = [
      record(.failed, name: "Beach.mov", error: "Quota exceeded"),
      record(.sent, name: "Dog.jpg"),
    ]
    #expect(ActivityFilter.all.apply(to: records, query: "  beach ").map(\.filename) == ["Beach.mov"])
    #expect(ActivityFilter.all.apply(to: records, query: "QUOTA").map(\.filename) == ["Beach.mov"])
    #expect(ActivityFilter.all.apply(to: records, query: "pictures").count == 2)
    #expect(ActivityFilter.failed.apply(to: records, query: "dog").isEmpty)
  }

  @Test("Filter counts match the filters' own membership")
  func filterCounts() {
    let records = [record(.pending), record(.pending), record(.sending), record(.sent), record(.failed)]
    let counts = ActivityFilter.counts(in: records)
    #expect(counts[.all] == 5)
    #expect(counts[.pending] == 3)
    #expect(counts[.uploaded] == 1)
    #expect(counts[.failed] == 1)
  }

  @Test("Only syncing spins; scanning is active but pulses")
  func emblemMotion() {
    #expect(BackupStatus.syncing(itemCount: 1).rotates)
    #expect(!BackupStatus.scanning(.folders).rotates)
    #expect(BackupStatus.scanning(.folders).isActive)
    #expect(!BackupStatus.upToDate.isActive)
    #expect(BackupStatus.stopping.isActive)
    #expect(!BackupStatus.stopping.rotates)
  }

  @Test("Only failed and limited-access cards offer a second action")
  func secondaryAction() {
    #expect(BackupStatus.failed(count: 1).hasSecondaryAction)
    #expect(BackupStatus.needsSource(.limitedPhotosAccess).hasSecondaryAction)
    #expect(!BackupStatus.upToDate.hasSecondaryAction)
    #expect(!BackupStatus.syncing(itemCount: 1).hasSecondaryAction)
  }

  @Test("Already-in-library is only reported for successful records")
  func alreadyInLibrary() {
    #expect(record(.sent, error: "Deduplicated by server").wasAlreadyInLibrary)
    #expect(!record(.failed, error: "Deduplicated by server").wasAlreadyInLibrary)
    #expect(!record(.sent).wasAlreadyInLibrary)
  }

  @Test("Pasted credentials are classified and blank input is rejected")
  func credentialClassification() {
    #expect(GoogleCredentialInput("  oauth2_4/abc  ") == .oauthToken("oauth2_4/abc"))
    #expect(
      GoogleCredentialInput("Email=a@b.com&Token=aas_et/x") == .credentialString("Email=a@b.com&Token=aas_et/x"))
    #expect(
      GoogleCredentialInput("androidId=1&Email=a@b.com") == .credentialString("androidId=1&Email=a@b.com"))
    #expect(GoogleCredentialInput("   ") == nil)
    #expect(GoogleCredentialInput.looksLikeCredential("oauth2_4/abc"))
    #expect(!GoogleCredentialInput.looksLikeCredential("hello world"))
  }

  @Test("Counts agree with their noun the same from the cache as from Foundation")
  func inflectedCounts() {
    // Twice each: the second answer comes from the cache.
    for _ in 0..<2 {
      #expect(ProductCopy.inflected("^[\(1) Item](inflect: true)") == "1 Item")
      #expect(ProductCopy.inflected("^[\(0) Item](inflect: true)") == "0 Items")
      #expect(ProductCopy.inflected("^[\(1234) Item](inflect: true)") == "1,234 Items")
      #expect(ProductCopy.inflected("^[\(1) day](inflect: true) left") == "1 day left")
      #expect(ProductCopy.inflected("^[\(23) day](inflect: true) left") == "23 days left")
      #expect(ProductCopy.inflected("Found ^[\(2) item](inflect: true) for you.") == "Found 2 items for you.")
    }
  }

  @Test("Only one count and noun is taken apart; anything else is left to Foundation")
  func inflectedPhraseParsing() {
    let phrase = InflectedPhrase("Found ^[1,234 item](inflect: true) here")
    #expect(phrase?.key == "2 item")
    #expect(phrase?.text(noun: "items") == "Found 1,234 items here")
    #expect(phrase?.noun(in: "Found 1,234 items here") == "items")
    // Foundation wrote something else around the noun: nothing is cached from it.
    #expect(phrase?.noun(in: "1,234 items found") == nil)
    #expect(InflectedPhrase("^[1 Item](inflect: true)")?.key == "1 Item")
    #expect(InflectedPhrase("No agreement here") == nil)
    #expect(InflectedPhrase("^[2 folder](inflect: true) and ^[1 album](inflect: true)") == nil)
    #expect(InflectedPhrase("^[Items](inflect: true)") == nil)
  }
}
