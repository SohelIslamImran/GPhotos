#if os(iOS)
  import Foundation
  import Network
  import Photos

  /// Backs up the photo library from the photo upload extension, which iOS runs on its own
  /// schedule, even after the app is closed from the app switcher.
  ///
  /// Each item is copied into the App Group, hashed and checked against the account like an
  /// upload the app makes, then sent by a background URLSession with the same request. iOS
  /// finishes the transfer on its own; a later run (of the extension, or of the app) commits it
  /// and leaves the result in the ledger for the app to record. Only the primary account backs
  /// up here, and nothing starts while the app is open, which uploads itself.
  public actor BackgroundUploader {
    public enum Outcome: Sendable, Equatable {
      /// Nothing is left to do until the library changes.
      case finished
      /// Uploads are running or waiting; iOS should call again.
      case moreToDo
    }

    /// Each job holds a copy of its files in the App Group until it is committed.
    static let maxJobs = 4
    /// A finished transfer doesn't make iOS call the extension again soon, so a run waits this
    /// long for its own transfers before looking for more to start.
    static let transferWait: TimeInterval = 25
    /// A transfer whose outcome hasn't arrived after this long is asked about directly: the
    /// process holding its session may be gone.
    static let statusCheckInterval: TimeInterval = 5 * 60
    /// How far the app pushes `BackgroundUploadLedger.appBusyUntil` ahead of now.
    public static let appBusyWindow: TimeInterval = 3 * 60

    private let store: BackgroundUploadLedgerStore
    private let manifestURL: URL
    private var session: URLSession?
    private var sessionMeteredAllowed: Bool?
    private let auth = GoogleAuthService()
    private var client: GooglePhotosMobileClient?
    private var credential: String?
    private var clientAccountEmail: String?
    private var uploadedCount = 0
    private var failedCount = 0
    private var needsRetry = false
    private var accountError: BackupNotificationEvent?
    private var isRunning = false
    /// Jobs whose commit failed this run, or that the app is committing: left for a later one.
    private var deferredJobIDs = Set<String>()

    public init(store: BackgroundUploadLedgerStore = .shared, manifestURL: URL = TransferManifestStore.defaultFileURL) {
      self.store = store
      self.manifestURL = manifestURL
    }

    private struct Context {
      let accountEmail: String
      let client: GooglePhotosMobileClient
      let settings: AppSettings
    }

    private enum ContextResult {
      case ready(Context)
      case signedOut
      /// The keychain couldn't be read (iOS can run the extension before the first unlock)
      /// or the credential couldn't be set: not the same as signed out, so nothing is dropped.
      case unavailable
    }

    /// The primary account's client, or nil when there is none to use right now.
    private func makeContext() async -> Context? {
      if case .ready(let context) = await loadContext() { return context }
      return nil
    }

    private func loadContext() async -> ContextResult {
      let account: GoogleAccount
      do {
        guard let loaded = try KeychainStore.loadAccount() else { return .signedOut }
        account = loaded
      } catch {
        BackgroundUploadLog.write("keychain unreadable: \(error.localizedDescription)")
        return .unavailable
      }
      let settings = AppSettingsStore.load()
      if clientAccountEmail != account.email || credential != account.credentialString || client == nil {
        do {
          try await auth.setCredential(account.credentialString)
        } catch {
          accountError = .accountNeedsSignIn(email: account.email)
          BackgroundUploadLog.write("run: account credential is unusable")
          return .unavailable
        }
        credential = account.credentialString
        clientAccountEmail = account.email
        let client = GooglePhotosMobileClient(
          authService: auth, isolatedSession: true, allowsExpensiveNetworkAccess: settings.uploadsOnMeteredNetworks)
        let accountEmail = account.email
        let store = store
        await client.setRateLimitObserver { limited, _ in
          if limited { store.update { $0.noteRateLimit(accountEmail: accountEmail, retryAfter: 0) } }
        }
        self.client = client
      }
      guard let client else { return .unavailable }
      await client.setAllowsExpensiveNetworkAccess(settings.uploadsOnMeteredNetworks)
      return .ready(Context(accountEmail: account.email, client: client, settings: settings))
    }

    // MARK: - Runs

    /// Finishes what has uploaded, then starts more until nothing is left or the extension cancels.
    public func run() async -> Outcome {
      guard !isRunning else { return .moreToDo }
      isRunning = true
      resetRun()
      defer { isRunning = false }
      let outcome = await process()
      if !store.read().appIsBusy() {
        await postSummary(fromExtension: true)
      }
      return outcome
    }

    private func process() async -> Outcome {
      let context: Context
      switch await loadContext() {
      case .ready(let ready):
        context = ready
      case .signedOut:
        BackgroundUploadLog.write("run: nobody signed in")
        dropJobs { _ in true }
        return .finished
      case .unavailable:
        return .moreToDo
      }
      dropJobs { $0.hasExpired(at: Date()) }
      store.removeAbandonedStaging()
      var scan: Scan?
      while true {
        if Task.isCancelled { return .moreToDo }
        if store.read().isRateLimited(accountEmail: context.accountEmail) {
          return .moreToDo
        }
        let canUseNetwork = await Self.networkAllowsUploads(meteredAllowed: context.settings.uploadsOnMeteredNetworks)
        if canUseNetwork { await finishJobs(context) }
        if Task.isCancelled || accountError != nil { return .moreToDo }
        let ledger = store.read()
        guard context.settings.autoSyncEnabled,
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        else {
          return ledger.jobs.isEmpty ? .finished : .moreToDo
        }
        if ledger.appIsBusy() {
          BackgroundUploadLog.write("run: the app is open and uploads itself")
          return .moreToDo
        }
        let limit = Self.maxJobs - ledger.jobs.count
        var candidates: [Candidate] = []
        if limit > 0 {
          if scan == nil || scan?.appWorkEpoch != ledger.appWorkEpoch {
            scan = makeScan(context: context, appWorkEpoch: ledger.appWorkEpoch)
          }
          if var currentScan = scan {
            candidates = findCandidates(context: context, scan: &currentScan, ledger: ledger, limit: limit)
            scan = currentScan
          }
        }
        if Task.isCancelled { return .moreToDo }
        if candidates.isEmpty && ledger.jobs.isEmpty {
          BackgroundUploadLog.write("run: everything is backed up")
          return needsRetry || hasHeldFailures(ledger, context: context) ? .moreToDo : .finished
        }
        guard canUseNetwork else {
          BackgroundUploadLog.write("run: waiting for a network uploads may use")
          return .moreToDo
        }
        for candidate in candidates {
          if Task.isCancelled { return .moreToDo }
          guard await start(candidate, context: context, appWorkEpoch: ledger.appWorkEpoch) else { return .moreToDo }
        }
        if !candidates.isEmpty, store.read().jobs.count < Self.maxJobs { continue }
        await waitForTransfers(until: Date().addingTimeInterval(Self.transferWait))
      }
    }

    private func hasHeldFailures(_ ledger: BackgroundUploadLedger, context: Context) -> Bool {
      let prefix = TransferRecord.accountScopedID("", accountEmail: context.accountEmail)
      return ledger.failures.keys.contains { $0.hasPrefix(prefix) && ledger.isHeldBack($0) }
    }

    /// Commits what has finished uploading. The app calls this when it opens, so an item the
    /// extension sent isn't held until iOS next runs it.
    public func finishJobs() async {
      guard !isRunning else { return }
      isRunning = true
      resetRun()
      defer { isRunning = false }
      dropJobs { $0.hasExpired(at: Date()) }
      if !Task.isCancelled, !store.read().jobs.isEmpty, let context = await makeContext(),
        !store.read().isRateLimited(accountEmail: context.accountEmail),
        await Self.networkAllowsUploads(meteredAllowed: context.settings.uploadsOnMeteredNetworks)
      {
        await finishJobs(context)
      }
      await postSummary(fromExtension: false)
    }

    private func resetRun() {
      deferredJobIDs = []
      uploadedCount = 0
      failedCount = 0
      needsRetry = false
      accountError = nil
    }

    private func postSummary(fromExtension: Bool) async {
      await BackupNotifier.shared.notifyBackgroundUploadCompletion(
        uploadedCount: uploadedCount, failedCount: failedCount, accountError: accountError, fromExtension: fromExtension)
    }

    private func waitForTransfers(until deadline: Date) async {
      while Date() < deadline, !Task.isCancelled {
        let jobs = store.read().jobs
        if jobs.isEmpty || jobs.contains(where: { $0.isSettled && !deferredJobIDs.contains($0.id) }) { return }
        try? await Task.sleep(for: .seconds(1))
      }
    }

    private func dropJobs(where shouldDrop: (BackgroundUploadJob) -> Bool) {
      let dropped = store.update { ledger in
        let dropped = ledger.jobs.filter(shouldDrop)
        ledger.jobs.removeAll(where: shouldDrop)
        return dropped
      }
      for job in dropped {
        try? FileManager.default.removeItem(at: store.stagingDirectory(forJob: job.id))
      }
    }

    /// Whether the network is up and, with uploads on metered networks turned off, unmetered:
    /// requests would otherwise wait for one, holding the run.
    static func networkAllowsUploads(meteredAllowed: Bool) async -> Bool {
      let monitor = NWPathMonitor()
      let (paths, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
      monitor.pathUpdateHandler = { path in
        continuation.yield(path.status == .satisfied && (meteredAllowed || !path.isExpensive))
      }
      monitor.start(queue: DispatchQueue(label: "org.gphotosapp.gphotos.background-upload.path"))
      let timeout = Task {
        try? await Task.sleep(for: .seconds(2))
        continuation.finish()
      }
      defer {
        monitor.cancel()
        timeout.cancel()
      }
      var iterator = paths.makeAsyncIterator()
      return await iterator.next() ?? false
    }

    // MARK: - Choosing What to Upload

    struct Candidate {
      let asset: PHAsset
      let recordID: String
      let role: AssetResourceRole
      let resourcesChecked: Bool
    }

    private struct Scan {
      let assets: PHFetchResult<PHAsset>
      let manifest: [String: TransferRecord]
      let excluded: Set<String>
      let appWorkEpoch: UUID?
      var index = 0
    }

    private func makeScan(context: Context, appWorkEpoch: UUID?) -> Scan {
      let options = AssetExportService.allFramesFetchOptions()
      options.predicate = NSPredicate(
        format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      return Scan(
        assets: PHAsset.fetchAssets(with: options),
        manifest: TransferManifestStore.storedRecords(fileURL: manifestURL),
        excluded: Self.assetsInAlbums(context.settings.excludedAlbumIDs),
        appWorkEpoch: appWorkEpoch)
    }

    private func findCandidates(context: Context, scan: inout Scan, ledger: BackgroundUploadLedger, limit: Int) -> [Candidate] {
      let held = ledger.heldRecordIDs
      let now = Date()
      let manifest = scan.manifest

      func needsUpload(_ recordID: String, version: TransferRecord.AssetVersion) -> Bool {
        if held.contains(recordID) || ledger.isHeldBack(recordID, at: now) { return false }
        guard let record = manifest[recordID] else { return true }
        if record.isSkipped { return false }
        switch record.status {
        case .sent, .deleted:
          return !record.hasBackedUpAsset(to: context.accountEmail, version: version)
        case .failed:
          // Held back by the app after it crashed preparing this item.
          return record.lastError != PreparationGuard.skippedMessage && record.isDueForAutomaticRetry(at: now)
        case .pending, .sending:
          return true
        }
      }

      var candidates: [Candidate] = []
      while scan.index < scan.assets.count, !Task.isCancelled {
        let asset = scan.assets.object(at: scan.index)
        guard !scan.excluded.contains(asset.localIdentifier) else {
          scan.index += 1
          continue
        }
        let primaryID = TransferRecord.accountScopedID(asset.localIdentifier, accountEmail: context.accountEmail)
        let rawID = TransferRecord.alternatePhotoID(forPrimaryID: primaryID)
        let originalID = TransferRecord.uneditedOriginalID(forPrimaryID: primaryID)
        let version = AssetExportService.version(of: asset)
        let primaryNeedsUpload = needsUpload(primaryID, version: version)
        let rawNeedsUpload =
          asset.mediaType == .image
          && needsUpload(rawID, version: version)
          && (manifest[rawID] != nil || manifest[primaryID]?.resourcesChecked != true || primaryNeedsUpload)
        let originalNeedsUpload =
          context.settings.backsUpUneditedOriginals && asset.hasAdjustments
          && needsUpload(originalID, version: version)
        // The RAW of a RAW+JPEG pair and an edited asset's original go up as records of their
        // own, as the app's scan queues them.
        var roles: [(id: String, role: AssetResourceRole)] = primaryNeedsUpload ? [(primaryID, .primary)] : []
        var checkedNoRAW = asset.mediaType == .video
        if rawNeedsUpload || originalNeedsUpload {
          let resources = PHAssetResource.assetResources(for: asset)
          if rawNeedsUpload {
            checkedNoRAW = AssetExportService.alternatePhotoResource(in: resources) == nil
            if !checkedNoRAW { roles.append((rawID, .alternatePhoto)) }
          }
          if originalNeedsUpload,
            AssetExportService.uneditedOriginalResource(mediaType: asset.mediaType, in: resources) != nil
          {
            roles.append((originalID, .uneditedOriginal))
          }
        }
        for (id, role) in roles {
          candidates.append(Candidate(asset: asset, recordID: id, role: role, resourcesChecked: role == .primary && checkedNoRAW))
          if candidates.count == limit { return candidates }
        }
        scan.index += 1
      }
      return candidates
    }

    private static func assetsInAlbums(_ albumIDs: Set<String>) -> Set<String> {
      guard !albumIDs.isEmpty else { return [] }
      var members = Set<String>()
      let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil)
      albums.enumerateObjects { album, _, _ in
        PHAsset.fetchAssets(in: album, options: AssetExportService.allFramesFetchOptions()).enumerateObjects { asset, _, _ in
          members.insert(asset.localIdentifier)
        }
      }
      return members
    }

    // MARK: - Starting an Upload

    private enum Prepared {
      case done(BackgroundUploadResult)
      case upload(BackgroundUploadJob)
    }

    /// Prepares and starts one item. False when the run should end: the network went away.
    private func start(_ candidate: Candidate, context: Context, appWorkEpoch: UUID?) async -> Bool {
      let jobID = UUID().uuidString
      let directory = store.stagingDirectory(forJob: jobID)
      guard
        store.persist({
          !$0.isRateLimited(accountEmail: context.accountEmail)
            && $0.claimForPreparation(recordID: candidate.recordID, jobID: jobID, epoch: appWorkEpoch)
        })
      else { return false }

      defer {
        store.update { $0.releasePreparation(candidate.recordID, jobID: jobID) }
      }
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = try await prepare(candidate, jobID: jobID, directory: directory, context: context)
        try checkCurrentAccount(context, needsAutoSync: true)
        switch prepared {
        case .done(let result):
          try? FileManager.default.removeItem(at: directory)
          guard
            store.persist({ ledger in
              guard ledger.ownsPreparation(recordID: candidate.recordID, jobID: jobID) else { return false }
              ledger.finish(jobID: jobID, with: result)
              return true
            })
          else { throw CancellationError() }
        case .upload(let job):
          try await send(job, directory: directory, context: context)
          BackgroundUploadLog.write("run: sending \(ByteFormat.string(job.byteCount))")
        }
        return true
      } catch {
        try? FileManager.default.removeItem(at: directory)
        if noteRunError(error, accountEmail: context.accountEmail) {
          store.update { ledger in
            if ledger.preparing[candidate.recordID]?.jobID == jobID {
              ledger.failures[candidate.recordID]?.count -= 1
            }
          }
          return false
        }
        recordFailure(candidate.recordID, reason: error.localizedDescription)
        return true
      }
    }

    private func checkCurrentAccount(_ context: Context, needsAutoSync: Bool = false) throws {
      try Task.checkCancellation()
      let settings = AppSettingsStore.load()
      guard let account = try KeychainStore.loadAccount(),
        account.email == context.accountEmail, account.credentialString == credential,
        settings.uploadsOnMeteredNetworks == context.settings.uploadsOnMeteredNetworks,
        !needsAutoSync
          || (settings.autoSyncEnabled
            && settings.excludedAlbumIDs == context.settings.excludedAlbumIDs
            && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
      else { throw CancellationError() }
    }

    /// Account, cancellation and network failures must leave other items eligible for retry.
    private func noteRunError(_ error: Error, accountEmail: String) -> Bool {
      if UploadWorkerPool.isAuthError(error) {
        accountError = .accountNeedsSignIn(email: accountEmail)
        return true
      }
      switch error as? GPhotosError {
      case .storageFull:
        accountError = .accountOutOfStorage(email: accountEmail)
      case .httpError(status: 408, body: _):
        return true
      case .httpError(status: 429, body: _):
        store.update { $0.noteRateLimit(accountEmail: accountEmail, retryAfter: 0) }
        return true
      default:
        break
      }
      return accountError != nil || Task.isCancelled || error is CancellationError || error is URLError
        || (error as? GPhotosError) == .cancelled || (error as? GPhotosError)?.isRetryable == true
    }

    private func recordFailure(_ recordID: String, reason: String, jobID: String? = nil) {
      let repeated = store.update { ledger in
        if let jobID { ledger.fail(jobID: jobID, reason: reason) } else { ledger.explainFailure(recordID, reason: reason) }
        return ledger.failures[recordID]?.count == BackgroundUploadLedger.maxAttempts
      }
      needsRetry = true
      if repeated { failedCount += 1 }
      BackgroundUploadLog.write("run: item failed: \(reason)")
    }

    private func prepare(
      _ candidate: Candidate, jobID: String, directory: URL, context: Context
    ) async throws -> Prepared {
      let asset = candidate.asset
      let settings = context.settings
      let isLivePhoto =
        candidate.role != .alternatePhoto && settings.pairLivePhotos && LivePhotoManager.isLivePhoto(asset)
      let mediaType = isLivePhoto ? "Live Photo" : (asset.mediaType == .video ? "Video" : "Photo")
      var note: String?
      if isLivePhoto {
        let live: LivePhotoExport?
        do {
          live = try await LivePhotoManager.exportLivePhoto(
            asset: asset, unedited: candidate.role == .uneditedOriginal,
            into: directory.appendingPathComponent("live", isDirectory: true))
        } catch {
          if Task.isCancelled || error is CancellationError || (error as? GPhotosError) == .cancelled { throw error }
          let error = AssetExportService.exportError(error)
          if case .notEnoughSpace = error { throw error }
          if error == .networkUnavailable { throw error }
          // The still is worth more than a failed item, so it goes up without its video.
          live = nil
          note = "Uploaded without motion"
        }
        if let live {
          return try await prepareLivePhoto(
            live, candidate: candidate, jobID: jobID, directory: directory, mediaType: mediaType, context: context)
        }
      }

      let resources = PHAssetResource.assetResources(for: asset)
      let fallbackName = "\(UUID().uuidString).\(asset.mediaType == .video ? "mov" : "jpg")"
      let filename =
        switch candidate.role {
        case .primary: AssetExportService.primaryUploadFilename(for: asset, in: resources)
        case .alternatePhoto: AssetExportService.alternatePhotoResource(in: resources)?.filenameOrEmpty
        case .uneditedOriginal:
          AssetExportService.uneditedOriginalResource(mediaType: asset.mediaType, in: resources)?.filenameOrEmpty
        }
      let name = filename.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
      let stagedName = "file." + ((name as NSString).pathExtension.isEmpty ? "bin" : (name as NSString).pathExtension)
      let (url, size) = try await AssetExportService.exportResource(
        asset: asset, role: candidate.role, to: directory.appendingPathComponent(stagedName))
      let sha1 = try await Self.hash(url)
      let client = context.client
      let capturedAt = Self.captureDate(of: name, asset: asset, settings: settings)

      if let existing = try await client.findExisting(sha1: sha1) {
        return .done(
          result(
            for: candidate, filename: name, mediaType: mediaType, byteCount: size, mediaKey: existing,
            sha1: sha1, pairedSHA1: nil, uploaded: false, foundInAccount: true, note: nil,
            accountEmail: context.accountEmail))
      }
      let uploadID = try await client.requestUploadToken(sha1B64: sha1.base64EncodedString(), size: size)
      return .upload(
        BackgroundUploadJob(
          id: jobID, recordID: candidate.recordID, accountEmail: context.accountEmail,
          assetLocalIdentifier: asset.localIdentifier, role: candidate.role, kind: .file, filename: name,
          mediaType: mediaType, creationDate: asset.creationDate, assetModifiedAt: asset.modificationDate,
          assetHadAdjustments: asset.hasAdjustments, assetAdjustmentTimestamp: asset.adjustmentTimestamp,
          resourcesChecked: candidate.resourcesChecked,
          capturedAt: capturedAt, byteCount: size, sha1: sha1, note: note,
          parts: [BackgroundUploadPart(stagedName: stagedName, size: size, uploadID: uploadID)]))
    }

    /// As the app uploads a Live Photo: nothing if the account holds the still with its motion,
    /// the motion alone if it holds only the still, otherwise both, committed together.
    private func prepareLivePhoto(
      _ live: LivePhotoExport, candidate: Candidate, jobID: String, directory: URL, mediaType: String,
      context: Context
    ) async throws -> Prepared {
      let client = context.client
      let photoSHA1 = try await Self.hash(live.photoURL)
      let videoSHA1 = try await Self.hash(live.videoURL)
      let photoExists = try await client.findExisting(sha1: photoSHA1)
      let videoExists: String? =
        if photoExists != nil {
          try await client.findExisting(sha1: videoSHA1, asLivePhotoMotion: true)
        } else {
          nil
        }
      let byteCount = live.photoSize + live.videoSize
      if let photoKey = photoExists, videoExists != nil {
        return .done(
          result(
            for: candidate, filename: live.photoFilename, mediaType: mediaType, byteCount: byteCount,
            mediaKey: photoKey, sha1: photoSHA1, pairedSHA1: videoSHA1, uploaded: false, foundInAccount: true,
            note: nil, accountEmail: context.accountEmail))
      }
      func stagedName(_ url: URL) -> String {
        String(url.path.dropFirst(directory.path.count).drop { $0 == "/" })
      }
      let videoPart = BackgroundUploadPart(
        stagedName: stagedName(live.videoURL), size: live.videoSize,
        uploadID: try await client.requestUploadToken(sha1B64: videoSHA1.base64EncodedString(), size: live.videoSize))
      var parts = [videoPart]
      if photoExists == nil {
        let photoPart = BackgroundUploadPart(
          stagedName: stagedName(live.photoURL), size: live.photoSize,
          uploadID: try await client.requestUploadToken(sha1B64: photoSHA1.base64EncodedString(), size: live.photoSize))
        parts.insert(photoPart, at: 0)
      }
      let asset = candidate.asset
      return .upload(
        BackgroundUploadJob(
          id: jobID, recordID: candidate.recordID, accountEmail: context.accountEmail,
          assetLocalIdentifier: asset.localIdentifier, role: candidate.role,
          kind: photoExists == nil ? .livePhoto : .livePhotoMotion, filename: live.photoFilename,
          videoFilename: live.videoFilename, mediaType: mediaType, creationDate: asset.creationDate,
          assetModifiedAt: asset.modificationDate,
          assetHadAdjustments: asset.hasAdjustments, assetAdjustmentTimestamp: asset.adjustmentTimestamp,
          resourcesChecked: candidate.resourcesChecked,
          capturedAt: Self.captureDate(of: live.photoFilename, asset: asset, settings: context.settings),
          byteCount: byteCount, sha1: photoSHA1, videoSHA1: videoSHA1, parts: parts))
    }

    /// Records the job, then hands each file to the background session. The job is on disk
    /// first, so an outcome always finds its part.
    private func send(_ job: BackgroundUploadJob, directory: URL, context: Context) async throws {
      var requests: [URLRequest] = []
      for part in job.parts {
        requests.append(try await context.client.backgroundUploadRequest(uploadID: part.uploadID))
      }
      try checkCurrentAccount(context, needsAutoSync: true)
      guard
        store.persist({ ledger in
          guard ledger.ownsPreparation(recordID: job.recordID, jobID: job.id),
            !ledger.isRateLimited(accountEmail: job.accountEmail)
          else { return false }
          ledger.jobs.append(job)
          ledger.releasePreparation(job.recordID, jobID: job.id)
          return true
        })
      else { throw CancellationError() }
      let session = activeSession(meteredAllowed: context.settings.uploadsOnMeteredNetworks)
      for (index, part) in job.parts.enumerated() {
        let task = session.uploadTask(with: requests[index], fromFile: directory.appendingPathComponent(part.stagedName))
        task.taskDescription = BackgroundUploadTransfers.taskDescription(jobID: job.id, part: index)
        task.resume()
      }
    }

    private func activeSession(meteredAllowed: Bool) -> URLSession {
      if let session, sessionMeteredAllowed == meteredAllowed { return session }
      session?.invalidateAndCancel()
      let session = BackgroundUploadTransfers.session(
        id: BackgroundUploadTransfers.newSessionID(), delegate: .init(store: store), meteredAllowed: meteredAllowed)
      self.session = session
      sessionMeteredAllowed = meteredAllowed
      return session
    }

    private static func hash(_ url: URL) async throws -> Data {
      let work = Task.detached(priority: .utility) { try GooglePhotosMobileClient.streamSHA1(fileURL: url) }
      return try await withTaskCancellationHandler {
        try await work.value
      } onCancel: {
        work.cancel()
      }
    }

    /// The date the app's upload would commit the item under.
    static func captureDate(of filename: String, asset: PHAsset, settings: AppSettings) -> Date {
      (settings.setDateFromFilename ? FilenameDateParser.parseDate(from: filename) : nil) ?? asset.creationDate ?? Date()
    }

    private func result(
      for candidate: Candidate, filename: String, mediaType: String, byteCount: Int64, mediaKey: String, sha1: Data,
      pairedSHA1: Data?, uploaded: Bool, foundInAccount: Bool, note: String?, accountEmail: String
    ) -> BackgroundUploadResult {
      BackgroundUploadResult(
        recordID: candidate.recordID, accountEmail: accountEmail, assetLocalIdentifier: candidate.asset.localIdentifier,
        role: candidate.role, filename: filename, mediaType: mediaType, creationDate: candidate.asset.creationDate,
        assetModifiedAt: candidate.asset.modificationDate, assetHadAdjustments: candidate.asset.hasAdjustments,
        assetAdjustmentTimestamp: candidate.asset.adjustmentTimestamp,
        resourcesChecked: candidate.resourcesChecked,
        byteCount: byteCount, mediaKey: mediaKey,
        sha1: sha1.base64EncodedString(), pairedSHA1: pairedSHA1?.base64EncodedString(), uploaded: uploaded,
        foundInAccount: foundInAccount, note: note)
    }

    // MARK: - Finishing an Upload

    private func finishJobs(_ context: Context) async {
      dropJobs { $0.accountEmail != context.accountEmail }
      for job in store.read().jobs where !deferredJobIDs.contains(job.id) {
        guard !Task.isCancelled, accountError == nil,
          !store.read().isRateLimited(accountEmail: context.accountEmail)
        else { return }
        guard await checkUnsettledParts(of: job, client: context.client) else {
          deferredJobIDs.insert(job.id)
          continue
        }
        guard let job = store.read().job(withID: job.id) else { continue }
        guard job.canCommit(at: Date()), !Task.isCancelled else { continue }
        if let failed = job.parts.first(where: { $0.state == .failed }) {
          if failed.error == "HTTP 429" {
            store.update { $0.failures[job.recordID]?.count -= 1 }
          }
          end(job, reason: failed.error ?? "Upload didn't finish")
        } else if job.parts.allSatisfy({ $0.state == .sent }) {
          await commit(job, context: context)
        } else if job.hasExpired(at: Date()) {
          end(job, reason: "Upload didn't finish")
        }
      }
    }

    /// Asks Google about parts that failed or whose outcome hasn't arrived: a transfer that
    /// completed is found complete even when its response was lost.
    private func checkUnsettledParts(of job: BackgroundUploadJob, client: GooglePhotosMobileClient) async -> Bool {
      let now = Date()
      for (index, part) in job.parts.enumerated() {
        guard !Task.isCancelled else { return false }
        let isDue =
          part.state == .failed
          || (part.state == .sending
            && now.timeIntervalSince(part.checkedAt ?? job.startedAt) > Self.statusCheckInterval)
        guard isDue else { continue }
        store.update { $0.updatePart(jobID: job.id, index: index) { $0.checkedAt = now } }
        do {
          if part.error == "HTTP 401" { _ = try await auth.bearerToken(forceRefresh: true) }
          let token: ScottyFinalizeToken?
          do {
            token = try await client.finishedUpload(uploadID: part.uploadID, size: part.size)
          } catch GPhotosError.httpError(status: 401, body: _) where part.error != "HTTP 401" {
            _ = try await auth.bearerToken(forceRefresh: true)
            token = try await client.finishedUpload(uploadID: part.uploadID, size: part.size)
          }
          store.update { ledger in
            ledger.updatePart(jobID: job.id, index: index) { part in
              if let token {
                part.state = .sent
                part.finalizeToken = token.raw
                part.error = nil
              }
            }
          }
        } catch {
          // Google no longer knows the upload, so it can't complete.
          if noteRunError(error, accountEmail: job.accountEmail) { return false }
          if GooglePhotosMobileClient.isPermanentUploadFailure(error) {
            store.update { ledger in
              ledger.updatePart(jobID: job.id, index: index) { part in
                guard part.state != .sent else { return }
                part.state = .failed
                part.error = part.error ?? error.localizedDescription
              }
            }
          }
        }
      }
      return true
    }

    private func commit(_ pending: BackgroundUploadJob, context: Context) async {
      var claimed: BackgroundUploadJob?
      guard
        store.persist({
          claimed = $0.claimForCommit(jobID: pending.id)
          return claimed != nil
        }), let job = claimed
      else {
        deferredJobIDs.insert(pending.id)
        return
      }
      let client = context.client
      do {
        try checkCurrentAccount(context)
        let mediaKey: String
        let recovered = job.commitWasAttempted == true ? try await existingCommit(for: job, client: client) : nil
        if let recovered {
          mediaKey = recovered
        } else {
          try checkCurrentAccount(context)
          mediaKey = try await commitParts(of: job, client: client)
        }
        let result = BackgroundUploadResult(
          recordID: job.recordID, accountEmail: job.accountEmail, assetLocalIdentifier: job.assetLocalIdentifier,
          role: job.role, filename: job.filename, mediaType: job.mediaType, creationDate: job.creationDate,
          assetModifiedAt: job.assetModifiedAt, assetHadAdjustments: job.assetHadAdjustments,
          assetAdjustmentTimestamp: job.assetAdjustmentTimestamp, resourcesChecked: job.resourcesChecked,
          byteCount: job.byteCount, mediaKey: mediaKey,
          sha1: job.sha1.base64EncodedString(), pairedSHA1: job.videoSHA1?.base64EncodedString(), uploaded: recovered == nil,
          foundInAccount: recovered != nil || job.kind == .livePhotoMotion, note: job.note)
        guard
          store.persist({ ledger in
            guard ledger.job(withID: job.id)?.committingUntil == job.committingUntil else { return false }
            ledger.finish(jobID: job.id, with: result)
            return true
          })
        else { throw CancellationError() }
        if result.uploaded { uploadedCount += 1 }
        try? FileManager.default.removeItem(at: store.stagingDirectory(forJob: job.id))
        BackgroundUploadLog.write("run: an upload was committed")
      } catch {
        if noteRunError(error, accountEmail: job.accountEmail) {
          store.update { ledger in
            if ledger.job(withID: job.id)?.committingUntil == job.committingUntil {
              ledger.releaseCommitClaim(jobID: job.id)
            }
          }
          deferredJobIDs.insert(job.id)
          BackgroundUploadLog.write("run: commit will be retried")
        } else {
          end(job, reason: error.localizedDescription)
        }
      }
    }

    /// A killed process may have reached Google before it could persist the response.
    private func existingCommit(for job: BackgroundUploadJob, client: GooglePhotosMobileClient) async throws -> String? {
      guard let key = try await client.findExisting(sha1: job.sha1) else { return nil }
      if let motion = job.videoSHA1, try await client.findExisting(sha1: motion, asLivePhotoMotion: true) == nil {
        return nil
      }
      return key
    }

    private func commitParts(of job: BackgroundUploadJob, client: GooglePhotosMobileClient) async throws -> String {
      let tokens = try job.parts.map { try ScottyFinalizeToken.parse($0.finalizeToken ?? Data()) }
      let modifiedAt = job.assetModifiedAt ?? job.capturedAt
      switch job.kind {
      case .file:
        return try await client.commit(
          token: try tokens[0].commitToken(), fileName: job.filename, sha1: job.sha1,
          timestamp: GooglePhotosMessages.timestampComponents(job.capturedAt).seconds)
      case .livePhoto:
        guard let videoSHA1 = job.videoSHA1, tokens.count == 2 else { throw GPhotosError.protobufDecode("Live Photo job") }
        return try await client.commitLivePhoto(
          input: LivePhotoCreateRequest(
            photoToken: tokens[0], videoToken: tokens[1], fileName: job.filename, photoSHA1: job.sha1,
            videoSHA1: videoSHA1, createdAt: job.capturedAt, modifiedAt: modifiedAt))
      case .livePhotoMotion:
        guard let videoSHA1 = job.videoSHA1 else { throw GPhotosError.protobufDecode("Live Photo job") }
        return try await client.reconcileLivePhoto(
          input: LivePhotoReconcileRequest(
            videoToken: tokens[0], fileName: job.videoFilename ?? job.filename, photoSHA1: job.sha1,
            videoSHA1: videoSHA1, createdAt: job.capturedAt, modifiedAt: modifiedAt))
      }
    }

    private func end(_ job: BackgroundUploadJob, reason: String) {
      recordFailure(job.recordID, reason: reason, jobID: job.id)
      try? FileManager.default.removeItem(at: store.stagingDirectory(forJob: job.id))
      BackgroundUploadLog.write("\(job.filename): failed: \(reason)")
    }
  }

#endif
