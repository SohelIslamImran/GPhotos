import Foundation
import Testing

@testable import GPhotosKit

@MainActor
@Suite("Account transitions")
struct AccountTransitionTests {
  private func account(_ name: String, credential: String? = nil) -> GoogleAccount {
    let email = "\(name)-\(UUID().uuidString)@example.com"
    return GoogleAccount(email: email, androidId: "123", credentialString: credential ?? "Email=\(email)&androidId=123")
  }

  private func engine(
    _ make: (GoogleAuthService, TransferManifestStore) -> SyncEngine = { SyncEngine(auth: $0, manifest: $1) }
  )
    -> SyncEngine
  {
    let path = TestTemporaryDirectory.root.appending(path: "transfers-\(UUID().uuidString).json")
    let auth = GoogleAuthService { _, _ in throw GPhotosError.notAuthenticated }
    let engine = make(auth, TransferManifestStore(fileURL: path))
    engine.publishAccountMetadata = {}
    engine.removeRemoteData = { _ in }
    engine.ingestSharedQueue = {}
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    engine.makeLibrary = { account, client in
      CloudLibrary(
        accountEmail: account.email, store: RemoteLibraryStore(accountEmail: account.email, directory: directory),
        fetcher: client, thumbnails: GoogleThumbnailSource(client: client, accountEmail: account.email), actionClient: nil)
    }
    return engine
  }

  @Test("Switching leaves the old account displayed and refuses new account work until retirement finishes")
  func blocksWorkDuringRetirement() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    var desired = first
    engine.readStoredAccounts = { ([first, second], desired) }
    await engine.loadAccounts()
    let old = try #require(engine.cloudLibrary)
    let generation = engine.accountGeneration

    let started = OneShotSignal()
    let release = OneShotSignal()
    engine.retireLibrary = { library in
      started.resume()
      await release.wait()
      await library.retire()
    }
    desired = second
    let change = Task { await engine.loadAccounts() }
    await started.wait()

    #expect(engine.selectedAccount == first)
    #expect(engine.cloudLibrary === old)
    #expect(engine.accountGeneration == generation)
    #expect(await engine.authService.installedCredential?.email == first.email)
    let cleanup = await engine.withAccountWork { "started" }
    #expect(cleanup == nil)
    let item = UploadQueueItem(
      id: "\(first.email)|one", fileURL: URL(fileURLWithPath: "/nonexistent"), filename: "one.jpg", fileSize: 1)
    #expect(engine.workerPool.start(items: [item], accountEmail: first.email) == .rejected)
    #expect(engine.workerPool.start(items: [item], accountEmail: second.email) == .rejected)

    release.resume()
    await change.value
    #expect(engine.selectedAccount == second)
    #expect(engine.cloudLibrary?.accountEmail == second.email)
    #expect(await engine.authService.installedCredential?.email == second.email)
    #expect(engine.accountGeneration == generation + 1)
    #expect(engine.workerPool.start(items: [item], accountEmail: first.email) == .rejected)
    await engine.cloudLibrary?.retire()
  }

  @Test("A folder scan interrupted by reauthentication replays only for the same account", .timeLimit(.minutes(1)))
  func folderScanReplaysAfterReauthentication() async throws {
    let engine = engine()
    let first = account("first")
    let other = account("other")
    let reauthenticated = GoogleAccount(
      email: first.email, androidId: first.androidId, credentialString: first.credentialString + "&language=en")
    var desired = first
    engine.readStoredAccounts = { ([desired, other], desired) }
    await engine.loadAccounts()
    let generation = engine.accountGeneration
    let retirement = OneShotSignal()
    let finish = OneShotSignal()
    let replayed = OneShotSignal()
    engine.retireLibrary = { library in
      retirement.resume()
      await finish.wait()
      await library.retire()
    }

    desired = reauthenticated
    let change = Task { await engine.loadAccounts() }
    await retirement.wait()
    #expect(engine.accountGeneration == generation)
    engine.replayInterruptedFolderScan(
      accountEmail: first.email, generation: generation,
      wake: (
        "folderScan",
        {
          #expect(engine.canUseSelectedAccount)
          #expect(engine.accountGeneration > generation)
          replayed.resume()
        }
      ))
    finish.resume()
    await change.value
    await replayed.wait()

    // A planner that returns after reauthentication is finished has the same replay.
    let late = OneShotSignal()
    engine.replayInterruptedFolderScan(
      accountEmail: first.email, generation: generation,
      wake: (
        "folderScan",
        {
          late.resume()
        }
      ))
    await late.wait()

    desired = other
    await engine.loadAccounts()
    #expect(!engine.shouldReplayFolderScan(accountEmail: first.email, generation: generation))
    await engine.cloudLibrary?.retire()
  }

  @Test("Overlapping loads queue and install the last stored selection")
  func overlappingLoads() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    let third = account("third")
    var desired = first
    var reads = 0
    engine.readStoredAccounts = {
      reads += 1
      return ([first, second, third], desired)
    }
    await engine.loadAccounts()
    let started = OneShotSignal()
    let release = OneShotSignal()
    var retirements: [String] = []
    engine.retireLibrary = { library in
      retirements.append(library.accountEmail)
      if retirements.count == 1 {
        started.resume()
        await release.wait()
      }
      await library.retire()
    }

    desired = second
    let firstLoad = Task { await engine.loadAccounts() }
    await started.wait()
    desired = third
    let queued = OneShotSignal()
    let secondLoad = Task {
      queued.resume()
      await engine.loadAccounts()
    }
    await queued.wait()
    #expect(reads == 2)
    #expect(await engine.authService.installedCredential?.email == first.email)
    #expect(retirements == [first.email])

    release.resume()
    await firstLoad.value
    await secondLoad.value
    #expect(reads == 3)
    #expect(retirements == [first.email, second.email])
    #expect(engine.selectedAccount == third)
    #expect(engine.cloudLibrary?.accountEmail == third.email)
    #expect(await engine.authService.installedCredential?.email == third.email)
    await engine.cloudLibrary?.retire()
  }

  @Test("A rejected credential leaves no installed bearer or attached library")
  func rejectedCredential() async throws {
    let engine = engine()
    let first = account("first")
    let broken = account("broken", credential: "Email=somebody-else@example.com")
    var desired = first
    engine.readStoredAccounts = { ([first, broken], desired) }
    await engine.loadAccounts()
    let old = try #require(engine.cloudLibrary)
    #expect(await engine.authService.installedCredential?.email == first.email)

    desired = broken
    await engine.loadAccounts()
    #expect(engine.credentialError != nil)
    #expect(engine.selectedAccount == nil)
    #expect(engine.cloudLibrary == nil)
    #expect(old.isRetired)
    #expect(await engine.authService.installedCredential == nil)
    await #expect(throws: GPhotosError.notAuthenticated) { try await engine.authService.bearerToken() }
  }

  @Test("Cancelling a bearer waiter returns before the underlying refresh")
  func cancellationDoesNotWaitForNetwork() async throws {
    let started = OneShotSignal()
    let release = OneShotSignal()
    let finished = OneShotSignal()
    let auth = GoogleAuthService { _, _ in
      started.resume()
      await release.wait()
      return GoogleAuthService.AuthToken(token: "fake", expiry: .distantFuture)
    }
    try await auth.setCredential("Email=test@example.com&androidId=123")
    let waiter = Task {
      defer { finished.resume() }
      return try await auth.bearerToken()
    }
    await started.wait()
    waiter.cancel()
    var returned = false
    await UploadWorkerPool.wait(timeout: .seconds(1)) {
      await finished.wait()
      returned = true
    }
    #expect(returned)
    release.resume()
    await #expect(throws: CancellationError.self) { try await waiter.value }
  }

  @Test("Removal bars new receipt imports and deletes records only after an in-flight import")
  func removalDrainsReceiptImport() async {
    let engine = engine()
    let first = account("first")
    let removed = account("removed")
    var stored = [first, removed]
    let keychainRemoved = OneShotSignal()
    let finishKeychainRead = OneShotSignal()
    engine.readStoredAccounts = {
      if stored.count == 1 {
        keychainRemoved.resume()
        await finishKeychainRead.wait()
      }
      return (stored, first)
    }
    engine.removeStoredAccount = { email in stored.removeAll { $0.email == email } }
    await engine.loadAccounts()

    let result = BackgroundUploadResult(
      recordID: "\(removed.email)|asset", accountEmail: removed.email, assetLocalIdentifier: "asset", role: .primary,
      filename: "IMG.jpg", mediaType: "Photo", creationDate: nil, assetModifiedAt: nil, byteCount: 20, mediaKey: "media",
      sha1: Data(repeating: 1, count: 20).base64EncodedString(), pairedSHA1: nil, uploaded: true, foundInAccount: false)
    var imported = false
    let started = OneShotSignal()
    let finishImport = OneShotSignal()
    let importTask = Task {
      await engine.withAccountWork {
        #expect(engine.acceptsBackgroundReceipt(accountEmail: removed.email))
        started.resume()
        await finishImport.wait()
        let outcome = await engine.manifestStore.recordBackgroundUpload(result)
        imported = true
        #expect(outcome == .recorded)
        #expect(!engine.acceptsBackgroundReceipt(accountEmail: removed.email))
      }
    }
    await started.wait()

    engine.removeRemoteData = { _ in #expect(imported) }
    let remove = Task { await engine.removeAccount(email: removed.email) }
    await keychainRemoved.wait()
    #expect(engine.accounts.contains(removed))
    #expect(!engine.acceptsBackgroundReceipt(accountEmail: removed.email))
    #expect(await engine.withAccountWork { "late import" } == nil)
    finishKeychainRead.resume()
    try? await Task.sleep(for: .milliseconds(50))
    finishImport.resume()
    _ = await importTask.value
    await remove.value
    #expect(await engine.manifestStore.record(for: result.recordID) == nil)
    #expect(!engine.acceptsBackgroundReceipt(accountEmail: removed.email))
    #expect(engine.acceptsBackgroundReceipt(accountEmail: first.email))
    await engine.cloudLibrary?.retire()
  }

  @Test("A filtered Activity result can only be presented for its account")
  func activityRowsAreAccountBound() {
    let records = [
      TransferRecord(id: "a@example.com|1", filename: "A.jpg", mediaType: "Photo", status: .failed),
      TransferRecord(id: "b@example.com|2", filename: "B.jpg", mediaType: "Photo", status: .failed),
    ]
    let a = AccountTransferBuckets(records: records, accountEmail: "a@example.com")
      .activityRows(filter: .failed, query: "jpg")
    let b = AccountTransferBuckets(records: records, accountEmail: "b@example.com")
      .activityRows(filter: .failed, query: "jpg")
    #expect(a.records(for: "a@example.com").map(\.filename) == ["A.jpg"])
    #expect(a.records(for: "b@example.com").isEmpty)
    #expect(a.records(for: nil).isEmpty)
    #expect(b.records(for: "b@example.com").map(\.filename) == ["B.jpg"])
  }

  @Test("An in-flight kept thumbnail cannot write after a lock or account removal and re-add")
  func keptThumbnailWriteRechecksLifetimeAndLock() throws {
    let email = account("thumbnail").email
    let key = "media"
    let bytes = Data([42])
    let folder = KeptThumbnails.directory(for: email)
    defer { KeptThumbnails.removeAll(accountEmail: email) }

    LockedItems.load([], accountEmail: email)
    let original = try #require(LockedItems.unlockedLifetime(key, accountEmail: email))
    LockedItems.insert([key], accountEmail: email)
    KeptThumbnails.write(bytes, mediaKey: key, accountEmail: email, lifetime: original)
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    KeptThumbnails.removeAll(accountEmail: email)
    KeptThumbnails.write(bytes, mediaKey: key, accountEmail: email, lifetime: original)
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    LockedItems.load([], accountEmail: email)
    KeptThumbnails.write(bytes, mediaKey: key, accountEmail: email, lifetime: original)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let current = try #require(LockedItems.unlockedLifetime(key, accountEmail: email))
    KeptThumbnails.write(bytes, mediaKey: key, accountEmail: email, lifetime: current)
    #expect(KeptThumbnails.data(mediaKey: key, accountEmail: email) == bytes)
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }

  private func record(_ id: String, for account: GoogleAccount, sentTo emails: [String] = []) -> TransferRecord {
    TransferRecord(
      id: "\(account.email)|\(id)", filename: "\(id).jpg", mediaType: "Photo", status: emails.isEmpty ? .pending : .sent,
      sentAccountEmails: Set(emails), mediaKeysByAccount: Dictionary(uniqueKeysWithValues: emails.map { ($0, "key-\($0)") }))
  }

  @Test("Changing, adding or removing a secondary leaves the primary's library, batch, scans and credential alone")
  func secondaryChangesKeepThePrimary() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    let third = account("third")
    var stored = [first, second]
    engine.readStoredAccounts = { (stored, first) }
    engine.setStoredMirror = { email, enabled in
      if let index = stored.firstIndex(where: { $0.email == email }) { stored[index].mirrorEnabled = enabled }
    }
    engine.removeStoredAccount = { email in stored.removeAll { $0.email == email } }
    await engine.loadAccounts()
    let library = try #require(engine.cloudLibrary)
    let credential = await engine.authService.installedCredential
    let generation = engine.accountGeneration
    engine.retireLibrary = { _ in Issue.record("The primary's library was retired") }

    let file = TestTemporaryDirectory.root.appending(path: "\(UUID().uuidString).jpg")
    try Data([1]).write(to: file)
    let pending = record("one", for: first)
    await engine.manifestStore.upsert(pending)
    #expect(await engine.manifestStore.claimForUpload(id: pending.id))
    let item = UploadQueueItem(id: pending.id, fileURL: file, filename: "one.jpg", fileSize: 1)
    engine.workerPool.pause()
    #expect(engine.workerPool.start(items: [item], accountEmail: first.email) == .started)
    engine.workerPool.pause()

    func expectPrimaryUntouched(_ change: String) async {
      #expect(engine.cloudLibrary === library, "\(change)")
      #expect(!library.isRetired, "\(change)")
      #expect(engine.isRunning && !engine.workerPool.isBatchCancelled, "\(change)")
      #expect(engine.accountGeneration == generation, "\(change)")
      #expect(await engine.authService.installedCredential == credential, "\(change)")
      #expect(engine.canUseSelectedAccount && engine.allowsAccountWork, "\(change)")
    }

    await engine.setMirrorEnabled(email: second.email, enabled: false)
    #expect(engine.accounts.last?.mirrorEnabled == false)
    await expectPrimaryUntouched("Keep a Copy off")
    await engine.setMirrorEnabled(email: second.email, enabled: true)
    #expect(engine.accounts.last?.mirrorEnabled == true)
    await expectPrimaryUntouched("Keep a Copy on")

    try await engine.addAccount {
      #expect(engine.canUseSelectedAccount)
      stored.append(third)
      return third
    }
    #expect(engine.accounts == stored)
    await expectPrimaryUntouched("added")

    await engine.manifestStore.upsert(record("copy", for: third, sentTo: [third.email]))
    var wasUsable = false
    engine.removeRemoteData = { email in
      #expect(email == third.email)
      // Backing up goes on, cleanup doesn't: what keeps a copy is changing.
      wasUsable = engine.canUseSelectedAccount && !engine.allowsAccountWork
    }
    await engine.removeAccount(email: third.email)
    #expect(wasUsable)
    #expect(engine.accounts.map(\.email) == [first.email, second.email])
    #expect(await engine.manifestStore.record(for: "\(third.email)|copy") == nil)
    await expectPrimaryUntouched("removed")

    #expect(engine.isBackupActive)
    engine.workerPool.cancel()
    await engine.workerPool.waitForCurrentBatch()
    #expect(!engine.isBackupActive)
    engine.retireLibrary = nil
    await library.retire()
  }

  @Test("A changed credential of the primary still goes through a full transition")
  func primaryCredentialChangeIsFull() async throws {
    let engine = engine()
    let first = account("first")
    var stored = first
    engine.readStoredAccounts = { ([stored], stored) }
    await engine.loadAccounts()
    let library = try #require(engine.cloudLibrary)
    try await engine.addAccount {
      stored = GoogleAccount(
        email: first.email, androidId: "456", credentialString: "Email=\(first.email)&androidId=456")
      return stored
    }
    #expect(library.isRetired)
    #expect(engine.cloudLibrary !== library)
    #expect(engine.selectedAccount == stored)
    await engine.cloudLibrary?.retire()
  }

  @Test("A secondary change stops cleanup, which starts again by itself only if it's automatic, and not the primary's albums")
  func secondaryChangeInterruptsCleanup() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    engine.readStoredAccounts = { ([first, second], first) }
    engine.setStoredMirror = { _, _ in }
    await engine.loadAccounts()
    var automaticRuns = 0
    var confirmedRuns = 0
    var cancelled: [String] = []
    func work(_ name: String, isPrimaryOnly: Bool = false, wake: SyncEngine.AccountWake? = nil) -> Task<Void, Never> {
      Task {
        _ = await engine.withAccountWork(isPrimaryOnly: isPrimaryOnly, wake: wake) {
          if name == "confirmed" { confirmedRuns += 1 }
          do { try await Task.sleep(for: .seconds(name == "albums" ? 0.3 : 30)) } catch { cancelled.append(name) }
        }
      }
    }
    let tasks = [
      work("automatic", wake: ("cleanup", { automaticRuns += 1 })), work("confirmed"), work("albums", isPrimaryOnly: true),
    ]
    #expect(await eventually { confirmedRuns == 1 })
    try await Task.sleep(for: .milliseconds(20))
    await engine.setMirrorEnabled(email: second.email, enabled: false)
    for task in tasks { await task.value }
    #expect(Set(cancelled) == ["automatic", "confirmed"])
    #expect(await eventually { automaticRuns == 1 })
    #expect(confirmedRuns == 1)
    await engine.cloudLibrary?.retire()
  }

  @Test("A removed primary's records aren't written back by a scan or import that started before")
  func removedAccountIsNotRecreated() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    var stored = [first, second]
    engine.readStoredAccounts = { (stored, stored.first) }
    engine.removeStoredAccount = { email in stored.removeAll { $0.email == email } }
    // A library under another name, so the removed account's data is deleted after its records.
    engine.makeLibrary = { _, client in
      CloudLibrary(
        accountEmail: "other@example.com",
        store: RemoteLibraryStore(
          accountEmail: "other@example.com", directory: TestTemporaryDirectory.root.appending(path: UUID().uuidString)),
        fetcher: client, thumbnails: GoogleThumbnailSource(client: client, accountEmail: "other@example.com"), actionClient: nil)
    }
    await engine.loadAccounts()
    let manifest = engine.manifestStore
    let old = record("old", for: first)
    let kept = record("kept", for: second, sentTo: [second.email, first.email])
    #expect(await manifest.upsertBatch([old, kept]))
    let scanned = engine.accountGeneration
    let late = record("late", for: first)
    let receipt = BackgroundUploadResult(
      recordID: "\(first.email)|receipt", accountEmail: first.email, assetLocalIdentifier: "asset", role: .primary,
      filename: "IMG.jpg", mediaType: "Photo", creationDate: nil, assetModifiedAt: nil, byteCount: 20, mediaKey: "media",
      sha1: Data(repeating: 1, count: 20).base64EncodedString(), pairedSHA1: nil, uploaded: true, foundInAccount: false)
    var checked = false
    engine.removeRemoteData = { email in
      #expect(email == first.email)
      #expect(await manifest.record(for: old.id) == nil)
      // The scan's own check fails by the time the records go.
      #expect(engine.accountGeneration != scanned)
      #expect(engine.selectedAccount == first)
      checked = true
      // Writes already past it.
      await manifest.upsertBatch([late], ifUnchangedSince: [:])
      await manifest.upsertBatch([late, kept])
      await manifest.upsert(late)
      #expect(await manifest.recordBackgroundUpload(receipt) == .deferred)
    }
    await engine.removeAccount(email: first.email)
    #expect(checked)
    let records = await manifest.allRecords()
    #expect(records.map(\.id) == [kept.id])
    #expect(records.first?.sentAccountEmails == [second.email])
    #expect(records.first?.mediaKeysByAccount == [second.email: "key-\(second.email)"])
    #expect(engine.selectedAccount == second)

    // Added again, it's an account like any other.
    try await engine.addAccount {
      stored.append(first)
      return first
    }
    #expect(await manifest.upsert(late))
    #expect(await manifest.record(for: late.id) != nil)
    await engine.cloudLibrary?.retire()
  }

  @Test("Work asked for while the primary changes runs once it's done, also if the change or a sign-in failed")
  func refusedWakesAreReplayed() async throws {
    let engine = engine()
    let first = account("first")
    let second = account("second")
    var desired = first
    var readGate: OneShotSignal?
    engine.readStoredAccounts = {
      await readGate?.wait()
      return ([first, second], desired)
    }
    await engine.loadAccounts()
    var ingested: [String?] = []
    engine.ingestSharedQueue = { ingested.append(engine.selectedAccount?.email) }
    let started = OneShotSignal()
    let release = OneShotSignal()
    engine.retireLibrary = { library in
      started.resume()
      await release.wait()
      await library.retire()
    }
    desired = second
    let change = Task { await engine.loadAccounts() }
    await started.wait()
    await engine.ingestSharedQueueItems()
    await engine.ingestSharedQueueItems()
    var scans = 0
    let scan: SyncEngine.AccountWake = ("scan", { scans += 1 })
    #expect(engine.replaysAfterAccountChange(scan))
    #expect(engine.replaysAfterAccountChange(scan))
    #expect(ingested.isEmpty)
    release.resume()
    await change.value
    try #require(await eventually { ingested == [second.email] && scans == 1 })
    #expect(!engine.replaysAfterAccountChange(scan))

    // Nothing changed, and the sign-in queued behind it fails.
    struct SignInFailed: Error {}
    readGate = OneShotSignal()
    let reload = Task { await engine.loadAccounts() }
    #expect(await eventually { engine.isChangingAccount })
    let signIn = Task { try await engine.addAccount { throw SignInFailed() } }
    await engine.ingestSharedQueueItems()
    #expect(ingested.count == 1)
    readGate?.resume()
    await reload.value
    await #expect(throws: SignInFailed.self) { try await signIn.value }
    try #require(await eventually { ingested == [second.email, second.email] })

    // A sign-in by itself holds nothing back meanwhile.
    await #expect(throws: SignInFailed.self) {
      try await engine.addAccount {
        await engine.ingestSharedQueueItems()
        throw SignInFailed()
      }
    }
    #expect(ingested.count == 3)

    // A pass an account change cuts short is run again.
    let reading = OneShotSignal()
    let finishReading = OneShotSignal()
    engine.ingestSharedQueue = {
      ingested.append(engine.selectedAccount?.email)
      guard ingested.count == 4 else { return }
      reading.resume()
      await finishReading.wait()
    }
    engine.retireLibrary = nil
    readGate = nil
    let pass = Task { await engine.ingestSharedQueueItems() }
    await reading.wait()
    desired = first
    await engine.loadAccounts()
    finishReading.resume()
    await pass.value
    #expect(await eventually { ingested.last == first.email })
    await engine.cloudLibrary?.retire()
  }

  private final class StagingEngine: SyncEngine {
    var cleanups = 0
    var wait: OneShotSignal?
    override func removeCompletedStagedCopies() async {
      cleanups += 1
      await wait?.wait()
    }
  }

  @Test("Backing up goes on while staged copies wait for Google Photos, and a later request is looked at after")
  func stagedCleanupHoldsNothingBack() async throws {
    var staging: StagingEngine!
    let engine = engine {
      staging = StagingEngine(auth: $0, manifest: $1)
      return staging
    }
    let first = account("first")
    engine.readStoredAccounts = { ([first], first) }
    await engine.loadAccounts()
    let answer = OneShotSignal()
    staging.wait = answer
    var backups = 0
    for _ in 0..<3 {
      await UploadWorkerPool.wait(timeout: .seconds(1)) { await engine.backUpDuringStagedCleanup { backups += 1 } }
      #expect(await eventually { staging.cleanups == 1 })
    }
    #expect(backups == 3)
    answer.resume()
    await engine.waitForStagedCleanup()
    #expect(staging.cleanups == 2)
    await engine.cloudLibrary?.retire()
  }

  #if os(macOS)
    @Test("A secondary receipt wakes staged cleanup without a new primary batch")
    func secondaryCompletionSchedulesStagedCleanup() async {
      let staging = engine { StagingEngine(auth: $0, manifest: $1) }
      let primary = account("primary")
      staging.readStoredAccounts = { ([primary], primary) }
      await staging.loadAccounts()
      staging.secondaryCopyDidComplete()
      await staging.waitForStagedCleanup()
      #expect((staging as? StagingEngine)?.cleanups == 1)
      #expect(!staging.workerPool.isRunning)
      await staging.cloudLibrary?.retire()
    }
  #endif

  @Test("Staged copies go only when everything that holds back any other removal allows it")
  func stagedCopiesShareEligibility() async {
    let store = TransferManifestStore(
      fileURL: TestTemporaryDirectory.root.appending(path: "transfers-\(UUID().uuidString).json"))
    let primary = account("primary")
    var secondary = account("secondary")
    func staged(_ name: String, found: Bool = false, status: TransferStatus = .sent) -> TransferRecord {
      var record = record(name, for: primary, sentTo: status == .sent ? [primary.email] : [])
      record.status = status
      record.sourcePath = "/drops/\(name).jpg"
      record.sentAt = Date()
      if found { record.foundInAccounts = [primary.email] }
      return record
    }
    let uploaded = staged("uploaded")
    let found = staged("found", found: true)
    let pending = staged("pending", status: .pending)
    await store.upsertBatch([uploaded, found, pending])
    let all = Set([uploaded, found, pending].map(\.id))
    func eligible(_ accounts: [GoogleAccount], includesFoundItems: Bool = false) async -> Set<String> {
      await store.eligibleStagedCopies(
        among: all, accountEmail: primary.email, accounts: accounts, includesFoundItems: includesFoundItems)
    }
    await store.setRetention(.never)
    #expect(await eligible([primary]) == [uploaded.id])
    #expect(await eligible([primary], includesFoundItems: true) == [uploaded.id, found.id])
    // A secondary that keeps a copy needs it first; one that doesn't isn't waited for.
    #expect(await eligible([primary, secondary]).isEmpty)
    secondary.mirrorEnabled = false
    #expect(await eligible([primary, secondary]) == [uploaded.id])
    #expect(
      await store.eligibleStagedCopies(
        among: [found.id], accountEmail: primary.email, accounts: [primary], includesFoundItems: false
      ).isEmpty)
  }
}
