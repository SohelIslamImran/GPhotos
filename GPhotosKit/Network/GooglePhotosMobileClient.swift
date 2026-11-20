import CryptoKit
import Foundation

public struct UploadOutcome: Sendable, Equatable {
  public enum Result: Sendable, Equatable {
    case uploaded(mediaKey: String)
    case alreadyExists(mediaKey: String)
  }

  public let result: Result
  public let sha1: Data

  public init(result: Result, sha1: Data) {
    self.result = result
    self.sha1 = sha1
  }
}

// MARK: - Upload progress delegate

public actor GooglePhotosMobileClient {

  public let authService: GoogleAuthService
  private let device: DeviceProfile = .metered
  private let uploadSession: URLSession
  private let dataSession: URLSession
  /// Thumbnails: on screen they're wanted now or not at all, so a request fails in seconds
  /// (and is tried again) rather than waiting minutes for a network to come back.
  private let thumbnailSession: URLSession
  /// Applied per request so a change takes effect without rebuilding the sessions. With
  /// expensive networks denied (cellular, Personal Hotspot), `waitsForConnectivity` holds
  /// requests until an unmetered network is available.
  private var allowsExpensiveNetworkAccess: Bool
  /// Google limits RPC calls per minute per user and answers 429 past it. Every request of
  /// this account shares the limit, so one 429 holds them all until the wait ends instead of
  /// each request retrying into the same refusal and its item failing.
  private var rateLimitedUntil: Date?
  private var rateLimitDelay = rateLimitBaseDelay
  static let rateLimitBaseDelay: TimeInterval = 60
  static let rateLimitMaxDelay: TimeInterval = 600
  /// Waits one request sits through before its 429 is returned: about 40 minutes in all.
  static let rateLimitMaxWaits = 7
  /// Told when a rate-limit wait starts (true) and ends (false), so the UI can say why
  /// nothing is moving. The sequence number lets a receiver drop reports that arrive late.
  private var rateLimitObserver: (@Sendable (Bool, Int) -> Void)?
  private var rateLimitWaiters = 0
  private var rateLimitReports = 0
  /// Thumbnails come from their own host with its own limit. A 429 there pauses thumbnails
  /// for seconds, not the account's RPC calls for minutes, and an RPC wait never holds the
  /// Library's thumbnails back.
  private var thumbnailRateLimitedUntil: Date?
  private var thumbnailRateLimitDelay = thumbnailRateLimitBaseDelay
  static let thumbnailRateLimitBaseDelay: TimeInterval = 2
  static let thumbnailRateLimitMaxDelay: TimeInterval = 30

  public init(authService: GoogleAuthService, isolatedSession: Bool = false, allowsExpensiveNetworkAccess: Bool = true) {
    self.authService = authService
    self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess

    let uploadConfig = isolatedSession ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
    uploadConfig.timeoutIntervalForRequest = 300  // 5 min idle packet timeout
    uploadConfig.timeoutIntervalForResource = 86400 * 7  // 7 days total transfer window
    uploadConfig.waitsForConnectivity = true
    uploadConfig.httpMaximumConnectionsPerHost = 10
    if isolatedSession {
      uploadConfig.httpCookieStorage = nil
      uploadConfig.httpCookieAcceptPolicy = .never
    }
    uploadSession = URLSession(configuration: uploadConfig)

    let dataConfig = isolatedSession ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
    dataConfig.timeoutIntervalForRequest = 120
    dataConfig.timeoutIntervalForResource = 600
    dataConfig.waitsForConnectivity = true
    if isolatedSession {
      dataConfig.httpCookieStorage = nil
      dataConfig.httpCookieAcceptPolicy = .never
    }
    dataSession = URLSession(configuration: dataConfig)

    let thumbnailConfig = isolatedSession ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
    thumbnailConfig.timeoutIntervalForRequest = 20
    thumbnailConfig.timeoutIntervalForResource = 60
    thumbnailConfig.waitsForConnectivity = false
    thumbnailConfig.httpMaximumConnectionsPerHost = 12
    if isolatedSession {
      thumbnailConfig.httpCookieStorage = nil
      thumbnailConfig.httpCookieAcceptPolicy = .never
    }
    thumbnailSession = URLSession(configuration: thumbnailConfig)
  }

  public func setRateLimitObserver(_ observer: @escaping @Sendable (Bool, Int) -> Void) {
    rateLimitObserver = observer
  }

  private func reportRateLimited(_ limited: Bool) {
    rateLimitReports += 1
    rateLimitObserver?(limited, rateLimitReports)
  }

  public func setAllowsExpensiveNetworkAccess(_ allowed: Bool) {
    allowsExpensiveNetworkAccess = allowed
  }

  // MARK: - Deduplication & Hash Check

  /// The media key of the item holding these bytes. With `asLivePhotoMotion` the hash is a
  /// Live Photo's motion, which matches only when it is attached to its still.
  public func findExisting(sha1: Data, asLivePhotoMotion: Bool = false) async throws -> String? {
    let token = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.dedup)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: token, language: language)
    request.httpBody = GooglePhotosMessages.encodeHashCheck(sha1Hash: sha1, asLivePhotoMotion: asLivePhotoMotion)

    let (data, response) = try await performData(request)
    try validateHTTP(response: response, data: data)
    return try GooglePhotosMessages.decodeRemoteMatches(data)
  }

  // MARK: - Scotty Upload Token

  public func requestUploadToken(sha1B64: String, size: Int64) async throws -> String {
    let token = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.uploadToken)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: token, language: language)
    request.setValue("sha1=\(sha1B64)", forHTTPHeaderField: "X-Goog-Hash")
    request.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
    request.httpBody = GooglePhotosMessages.encodeGetUploadToken(fileSizeBytes: size)

    let (data, response) = try await performData(request)
    try validateHTTP(response: response, data: data)
    guard let http = response as? HTTPURLResponse else {
      throw GPhotosError.httpError(status: -1, body: "No HTTP response")
    }
    guard let uploadID = http.value(forHTTPHeaderField: "X-GUploader-UploadID"), !uploadID.isEmpty else {
      throw GPhotosError.uploadTokenMissingHeader
    }
    return uploadID
  }

  // MARK: - Scotty Stream Upload

  private enum ScottyStatusResult: Sendable {
    case completed(ScottyFinalizeToken)
    case incomplete(nextOffset: Int64)
  }

  /// The offset Scotty has persisted, from a 308 response. Without a `Range` header the
  /// server has received nothing, so the upload restarts at zero.
  static func persistedOffset(from response: HTTPURLResponse, totalSize: Int64) -> Int64 {
    guard let rangeHeader = response.value(forHTTPHeaderField: "Range") else { return 0 }
    let clean = rangeHeader.trimmingCharacters(in: .whitespaces)
    let part = clean.hasPrefix("bytes=") ? clean.dropFirst("bytes=".count) : Substring(clean)
    let pieces = part.split(separator: "-")
    guard pieces.count == 2, let lastByte = Int64(pieces[1]), lastByte >= 0, lastByte < Int64.max else { return 0 }
    return min(lastByte + 1, totalSize)
  }

  /// A 4xx other than 401 (refreshed and retried), 408 or 429 will not succeed on retry.
  static func isPermanentUploadFailure(_ error: Error) -> Bool {
    switch error as? GPhotosError {
    case .httpError(let status, _):
      return (400...499).contains(status) && ![401, 408, 429].contains(status)
    case .authFailed, .notAuthenticated, .invalidCredential, .missingCredential, .storageFull:
      return true
    default:
      return false
    }
  }

  private func queryScottyStatus(uploadURL: URL, bearer: String, totalSize: Int64, language: String) async throws -> ScottyStatusResult {
    var queryReq = URLRequest(url: uploadURL)
    queryReq.httpMethod = "PUT"
    queryReq.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    queryReq.setValue(device.photosUserAgent(languageCode: language), forHTTPHeaderField: "User-Agent")
    queryReq.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    queryReq.setValue(language, forHTTPHeaderField: "Accept-Language")
    queryReq.setValue("bytes */\(totalSize)", forHTTPHeaderField: "Content-Range")
    queryReq.setValue("0", forHTTPHeaderField: "Content-Length")
    queryReq.httpBody = Data()
    queryReq.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess

    let (data, response) = try await dataSession.data(for: queryReq)
    guard let http = response as? HTTPURLResponse else {
      throw GPhotosError.httpError(status: -1, body: "No response from Scotty status query")
    }

    if (200...299).contains(http.statusCode) {
      let token = try ScottyFinalizeToken.parse(data)
      return .completed(token)
    }

    if http.statusCode == 308 {
      return .incomplete(nextOffset: Self.persistedOffset(from: http, totalSize: totalSize))
    }

    try Self.throwHTTPError(status: http.statusCode, data: data)
  }

  // MARK: - Progress Tracker & Sub-chunk Delegate

  final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _maxReported: Int64 = 0
    private var lastReportTime = Date.distantPast

    init(initial: Int64 = 0) {
      self._maxReported = initial
    }

    func report(sent: Int64, total: Int64, handler: (@Sendable (Int64, Int64) -> Void)?) {
      lock.lock()
      if sent > _maxReported {
        _maxReported = sent
      }
      let current = _maxReported
      let now = Date()
      let shouldReport = current >= total || now.timeIntervalSince(lastReportTime) >= 0.5
      if shouldReport {
        lastReportTime = now
      }
      lock.unlock()
      if shouldReport {
        handler?(min(current, total), total)
      }
    }
  }

  final class ChunkProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let baseOffset: Int64
    let onChunkProgress: @Sendable (Int64) -> Void

    init(baseOffset: Int64, onChunkProgress: @escaping @Sendable (Int64) -> Void) {
      self.baseOffset = baseOffset
      self.onChunkProgress = onChunkProgress
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64,
      totalBytesExpectedToSend: Int64
    ) {
      onChunkProgress(baseOffset + totalBytesSent)
    }
  }

  public func uploadWithScotty(
    fileURL: URL,
    token: String,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> ScottyFinalizeToken {
    let uploadURL = try Self.uploadURL(uploadID: token)
    let totalSize = try fileSize(at: fileURL)
    var bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()

    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    // 16 MB chunks aligned to 256 KiB
    let chunkSize: Int64 = 16 * 1024 * 1024
    var currentOffset: Int64 = 0
    var retriesForCurrentChunk = 0
    let maxRetriesPerChunk = 6
    var rateLimitWaits = 0
    var refreshedAfterForbidden = false

    let tracker = ProgressTracker(initial: 0)
    let reportProgress: @Sendable (Int64) -> Void = { sent in
      tracker.report(sent: sent, total: totalSize, handler: onProgress)
    }

    reportProgress(0)

    while currentOffset < totalSize {
      try Task.checkCancellation()
      let bytesRemaining = totalSize - currentOffset
      let thisChunkSize = Int(min(chunkSize, bytesRemaining))

      try fileHandle.seek(toOffset: UInt64(currentOffset))
      guard let chunkData = try fileHandle.read(upToCount: thisChunkSize), !chunkData.isEmpty else {
        throw GPhotosError.fileReadFailed("Failed to read bytes at offset \(currentOffset) for \(fileURL.lastPathComponent)")
      }

      let endByte = currentOffset + Int64(chunkData.count) - 1

      var request = URLRequest(url: uploadURL)
      request.httpMethod = "PUT"
      request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
      request.setValue(device.photosUserAgent(languageCode: language), forHTTPHeaderField: "User-Agent")
      request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
      request.setValue(language, forHTTPHeaderField: "Accept-Language")
      request.setValue("bytes \(currentOffset)-\(endByte)/\(totalSize)", forHTTPHeaderField: "Content-Range")
      request.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")
      request.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess

      let chunkBaseOffset = currentOffset
      let delegate = ChunkProgressDelegate(baseOffset: chunkBaseOffset) { sent in
        reportProgress(sent)
      }

      do {
        let (responseData, response) = try await uploadSession.upload(for: request, from: chunkData, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
          throw GPhotosError.httpError(status: -1, body: "No response from Scotty")
        }

        if http.statusCode == 401 {
          // Token expired during upload; force refresh and retry chunk
          bearer = try await authService.bearerToken(forceRefresh: true)
          retriesForCurrentChunk += 1
          if retriesForCurrentChunk >= maxRetriesPerChunk {
            throw GPhotosError.authFailed(status: 401, body: "Unauthorized during upload")
          }
          continue
        }
        // A revoked token can also come back as 403; one refresh tells it apart from a
        // refusal that stays.
        if http.statusCode == 403, !refreshedAfterForbidden {
          refreshedAfterForbidden = true
          bearer = try await authService.bearerToken(forceRefresh: true)
          continue
        }

        if http.statusCode == 429, rateLimitWaits < Self.rateLimitMaxWaits {
          rateLimitWaits += 1
          try await waitOutRateLimit(after: http)
          continue
        }

        if (200...299).contains(http.statusCode) {
          // Final chunk committed and server returned finalize token
          noteRequestSucceeded()
          let finalizeToken = try ScottyFinalizeToken.parse(responseData)
          reportProgress(totalSize)
          return finalizeToken
        } else if http.statusCode == 308 {
          // The server's persisted offset is authoritative, even when it moves backwards.
          let persisted = Self.persistedOffset(from: http, totalSize: totalSize)
          if persisted > currentOffset {
            retriesForCurrentChunk = 0
            noteRequestSucceeded()
          } else {
            retriesForCurrentChunk += 1
            if retriesForCurrentChunk >= maxRetriesPerChunk {
              throw GPhotosError.httpError(status: 308, body: "Upload made no progress at offset \(persisted)")
            }
            try await Task.sleep(for: .seconds(min(1 << retriesForCurrentChunk, 30)))
          }
          currentOffset = persisted
          reportProgress(currentOffset)
        } else {
          try Self.throwHTTPError(status: http.statusCode, data: responseData)
        }
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
          throw CancellationError()
        }
        retriesForCurrentChunk += 1
        if retriesForCurrentChunk >= maxRetriesPerChunk || Self.isPermanentUploadFailure(error) {
          // A lost connection must read as one, so the upload waits for the network instead
          // of failing.
          if let urlError = error as? URLError { throw GPhotosError.from(urlError: urlError) }
          throw error
        }

        let delay = UInt64(min(pow(2.0, Double(retriesForCurrentChunk)), 30.0)) * 1_000_000_000
        try await Task.sleep(nanoseconds: delay)

        // Query Scotty to see what byte it actually received
        do {
          let status = try await queryScottyStatus(uploadURL: uploadURL, bearer: bearer, totalSize: totalSize, language: language)
          switch status {
          case .completed(let token):
            reportProgress(totalSize)
            return token
          case .incomplete(let nextOffset):
            currentOffset = nextOffset
            reportProgress(currentOffset)
          }
        } catch {
          // A gone or rejected session will not recover; anything else retries the current offset.
          if Self.isPermanentUploadFailure(error) { throw error }
        }
      }
    }

    // If all bytes sent but need finalize token, query Scotty status
    let finalStatus = try await queryScottyStatus(uploadURL: uploadURL, bearer: bearer, totalSize: totalSize, language: language)
    switch finalStatus {
    case .completed(let token):
      reportProgress(totalSize)
      return token
    case .incomplete:
      throw GPhotosError.httpError(status: -1, body: "Upload reached end but finalize token was not returned")
    }
  }

  // MARK: - Background Uploads

  /// The request a background URLSession sends a whole file with, from the photo upload
  /// extension: a single PUT of the file with no range.
  public func backgroundUploadRequest(uploadID: String) async throws -> URLRequest {
    var request = URLRequest(url: try Self.uploadURL(uploadID: uploadID))
    request.httpMethod = "PUT"
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(language, forHTTPHeaderField: "Accept-Language")
    request.setValue(device.photosUserAgent(languageCode: language), forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
    return request
  }

  /// The finalize token of a finished upload, or nil while Google is still missing bytes. For
  /// a background upload whose response was lost with the process that started it.
  public func finishedUpload(uploadID: String, size: Int64) async throws -> ScottyFinalizeToken? {
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    let status = try await queryScottyStatus(
      uploadURL: try Self.uploadURL(uploadID: uploadID), bearer: bearer, totalSize: size, language: language)
    switch status {
    case .completed(let token): return token
    case .incomplete: return nil
    }
  }

  private static func uploadURL(uploadID: String) throws -> URL {
    guard var components = URLComponents(url: GPhotosEndpoints.uploadToken, resolvingAgainstBaseURL: false) else {
      throw GPhotosError.fileReadFailed("Invalid upload URL")
    }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "upload_id", value: uploadID)]
    guard let url = components.url else { throw GPhotosError.fileReadFailed("Invalid upload URL with token") }
    return url
  }

  public func upload(
    fileURL: URL,
    token: String,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> CommitToken {
    let finalizeToken = try await uploadWithScotty(fileURL: fileURL, token: token, onProgress: onProgress)
    return try finalizeToken.commitToken()
  }

  // MARK: - Single Commit

  public func commit(
    token: CommitToken,
    fileName: String,
    sha1: Data,
    timestamp: Int64,
    quality: Int64 = 3
  ) async throws -> String {
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.commit)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: bearer, language: language)
    request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
    request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
    request.httpBody = GooglePhotosMessages.encodeCommitUpload(
      commitToken: token,
      fileName: fileName,
      sha1Hash: sha1,
      timestampSeconds: timestamp,
      device: device,
      quality: quality
    )

    let (data, response) = try await performData(request)
    try validateHTTP(response: response, data: data)
    return try GooglePhotosMessages.decodeCommitUploadResponse(data)
  }

  // MARK: - Live Photos Commit

  public func commitLivePhoto(input: LivePhotoCreateRequest) async throws -> String {
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.createMediaItems)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: bearer, language: language)
    request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
    request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
    request.httpBody = try GooglePhotosMessages.encodeLivePhotoCreate(input: input)

    let (data, response) = try await performData(request)
    try validateHTTP(response: response, data: data)
    return try GooglePhotosMessages.decodeCreateMediaItemsResponse(data)
  }

  public func reconcileLivePhoto(input: LivePhotoReconcileRequest) async throws -> String {
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.createMediaItems)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: bearer, language: language)
    request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
    request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
    request.httpBody = try GooglePhotosMessages.encodeLivePhotoReconcile(input: input)

    let (data, response) = try await performData(request)
    try validateHTTP(response: response, data: data)
    return try GooglePhotosMessages.decodeCreateMediaItemsResponse(data)
  }

  // MARK: - Album API

  public func createAlbum(albumName: String, mediaKeys: [String]) async throws -> String {
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: GPhotosEndpoints.createAlbum)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: bearer, language: language)
    request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
    request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
    request.httpBody = GooglePhotosMessages.encodeCreateAlbum(albumName: albumName, mediaKeys: mediaKeys, device: device)

    // A retry after the server already created the album would create a second one
    // with the same title.
    let (data, response) = try await performData(request, retriesTransportFailures: false)
    try validateHTTP(response: response, data: data)
    return try GooglePhotosMessages.decodeCreateAlbumResponse(data)
  }

  public func addMediaToAlbum(albumMediaKey: String, mediaKeys: [String]) async throws {
    guard !mediaKeys.isEmpty else { return }
    let bearer = try await authService.bearerToken()
    let language = await authService.credentialLanguage()

    // Process in batches of 500 items max (Google Photos API batch limit)
    let batchSize = 500
    for i in stride(from: 0, to: mediaKeys.count, by: batchSize) {
      let chunk = Array(mediaKeys[i..<min(i + batchSize, mediaKeys.count)])
      var request = URLRequest(url: GPhotosEndpoints.addMediaToAlbum)
      request.httpMethod = "POST"
      applyCommonHeaders(&request, bearer: bearer, language: language)
      request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
      request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
      request.httpBody = GooglePhotosMessages.encodeAddMediaToAlbum(albumMediaKey: albumMediaKey, mediaKeys: chunk, device: device)

      let (data, response) = try await performData(request)
      try validateHTTP(response: response, data: data)
    }
  }

  // MARK: - High Level Single File Upload

  public func uploadFile(
    at fileURL: URL,
    fileName: String? = nil,
    quality: Int64 = 3,
    useFilenameDate: Bool = true,
    creationDate: Date? = nil,
    sha1: Data? = nil,
    onHashingProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> UploadOutcome {
    let resolvedSHA1: Data
    if let sha1 {
      resolvedSHA1 = sha1
    } else {
      resolvedSHA1 = try await Self.hashFile(fileURL, onProgress: onHashingProgress)
    }
    let sha1B64 = resolvedSHA1.base64EncodedString()
    let size = try fileSize(at: fileURL)
    let name = fileName ?? fileURL.lastPathComponent

    if let existingKey = try await findExisting(sha1: resolvedSHA1) {
      return UploadOutcome(result: .alreadyExists(mediaKey: existingKey), sha1: resolvedSHA1)
    }

    let uploadToken = try await requestUploadToken(sha1B64: sha1B64, size: size)
    let finalizeToken = try await uploadWithScotty(fileURL: fileURL, token: uploadToken, onProgress: onProgress)
    let commitToken = try finalizeToken.commitToken()

    let date =
      (useFilenameDate ? FilenameDateParser.parseDate(from: name) : nil)
      ?? creationDate
      ?? Self.earliestFileDate(fileURL)
      ?? Date()
    let timestamp = GooglePhotosMessages.timestampComponents(date).seconds

    let mediaKey = try await commit(
      token: commitToken,
      fileName: name,
      sha1: resolvedSHA1,
      timestamp: timestamp,
      quality: quality
    )
    return UploadOutcome(result: .uploaded(mediaKey: mediaKey), sha1: resolvedSHA1)
  }

  /// A copied file gets a new creation date but keeps its modification date, so the
  /// earlier of the two is the closer one to when it was captured.
  private static func earliestFileDate(_ url: URL) -> Date? {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min()
  }

  @concurrent
  private static func hashFile(_ fileURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws -> Data {
    try streamSHA1(fileURL: fileURL, onProgress: onProgress)
  }

  public static func streamSHA1(
    fileURL: URL,
    chunkSize: Int = 2_097_152,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) throws -> Data {
    let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw GPhotosError.fileReadFailed("Cannot open \(fileURL.lastPathComponent)")
    }
    defer { close(descriptor) }

    var info = stat()
    let totalSize = fstat(descriptor, &info) == 0 ? Int64(info.st_size) : 0

    var hasher = Insecure.SHA1()
    var bytesRead: Int64 = 0
    var lastReportTime = Date.distantPast
    // One buffer for the whole file: a fresh chunk per read meant an allocation (and,
    // through FileHandle, an autoreleased copy) for every 2 MB of every file hashed.
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
    defer { buffer.deallocate() }

    while true {
      try Task.checkCancellation()
      let count = read(descriptor, buffer.baseAddress, chunkSize)
      if count < 0 {
        if errno == EINTR { continue }
        throw GPhotosError.fileReadFailed("Cannot read \(fileURL.lastPathComponent)")
      }
      if count == 0 { break }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
      bytesRead += Int64(count)

      if let onProgress {
        let now = Date()
        if now.timeIntervalSince(lastReportTime) >= 0.5 || (totalSize > 0 && bytesRead >= totalSize) {
          lastReportTime = now
          onProgress(bytesRead, totalSize > 0 ? totalSize : bytesRead)
        }
      }
    }
    return Data(hasher.finalize())
  }

  // MARK: - Library

  public func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
    try LibraryMessages.decodeLibraryUpdate(
      try await libraryRPC(GPhotosEndpoints.librarySync, body: LibraryMessages.libraryState(syncToken: syncToken)))
  }

  public func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate {
    try LibraryMessages.decodeLibraryUpdate(
      try await libraryRPC(GPhotosEndpoints.librarySync, body: LibraryMessages.initialPage(resumeToken: resumeToken)))
  }

  public func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate {
    try LibraryMessages.decodeLibraryUpdate(
      try await libraryRPC(
        GPhotosEndpoints.librarySync, body: LibraryMessages.deltaPage(resumeToken: resumeToken, syncToken: syncToken)))
  }

  /// Moves items to Google Photos' Trash, where they stay for 60 days. The request omits the extension headers.
  public func trash(dedupKeys: [String]) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.trashItems, body: LibraryMessages.trash(dedupKeys: dedupKeys, device: device),
      extensionHeaders: false, isAction: true)
  }

  /// Deletes items in Google Photos' Trash for good. Sent like `trash`, without the
  /// extension headers.
  public func deleteForever(dedupKeys: [String]) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.trashItems, body: LibraryMessages.deleteForever(dedupKeys: dedupKeys),
      extensionHeaders: false, isAction: true)
  }

  public func restoreFromTrash(dedupKeys: [String]) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.trashItems, body: LibraryMessages.restore(dedupKeys: dedupKeys, device: device), isAction: true)
  }

  public func setFavorite(dedupKey: String, isFavorite: Bool) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.setFavorite, body: LibraryMessages.favorite(dedupKey: dedupKey, isFavorite: isFavorite),
      isAction: true)
  }

  public func setArchived(dedupKeys: [String], isArchived: Bool) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.setArchived, body: LibraryMessages.archive(dedupKeys: dedupKeys, isArchived: isArchived),
      isAction: true)
  }

  public func setCaption(dedupKey: String, caption: String) async throws {
    _ = try await libraryRPC(
      GPhotosEndpoints.setCaption, body: LibraryMessages.caption(dedupKey: dedupKey, caption: caption), isAction: true)
  }

  /// Fetches a video's HLS playlist with a POST request.
  public func streamManifest(mediaKey: String, contentVersion: Int?) async throws -> Data {
    var request = try await mediaRequest(GPhotosEndpoints.streamManifest(mediaKey: mediaKey, contentVersion: contentVersion))
    request.httpMethod = "POST"
    let (data, response) = try await performData(request, isBrowsing: true)
    try validateHTTP(response: response, data: data)
    return data
  }

  public func downloadURLs(mediaKey: String) async throws -> (edited: URL?, original: URL?) {
    try LibraryMessages.decodeDownloadURLs(
      try await libraryRPC(GPhotosEndpoints.prepareDownload, body: LibraryMessages.downloadURLs(mediaKey: mediaKey)))
  }

  /// A thumbnail as JPEG bytes, sized to fit `width` × `height` (or filling it, cropped).
  public func thumbnail(
    mediaKey: String, width: Int?, height: Int?, contentVersion: Int?, crop: Bool = false, waitsOutRateLimit: Bool = true
  ) async throws -> Data {
    let request = try await mediaRequest(
      GPhotosEndpoints.thumbnail(
        mediaKey: mediaKey, width: width, height: height, contentVersion: contentVersion, crop: crop))
    let (data, response) = try await performThumbnail(request, waitsOutRateLimit: waitsOutRateLimit)
    try validateHTTP(response: response, data: data)
    return data
  }

  /// A thumbnail fetch. On screen (`waitsOutRateLimit`) it sits through a short 429 pause
  /// and a refreshed token; for indexing it gives up at once, so a pass stops instead of
  /// competing with what's on screen.
  private func performThumbnail(_ request: URLRequest, waitsOutRateLimit: Bool) async throws -> (Data, URLResponse) {
    var request = request
    request.allowsExpensiveNetworkAccess = true
    var refreshedAuth = false
    var waits = 0
    while true {
      if let until = thumbnailRateLimitedUntil, until > Date() {
        guard waitsOutRateLimit, waits < 3 else { throw GPhotosError.httpError(status: 429, body: "") }
        waits += 1
        try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
        continue
      }
      let (data, response): (Data, URLResponse)
      do {
        (data, response) = try await thumbnailSession.data(for: request)
      } catch let error as URLError {
        throw GPhotosError.from(urlError: error)
      }
      let status = (response as? HTTPURLResponse)?.statusCode
      if status == 401 || status == 403, !refreshedAuth {
        refreshedAuth = true
        let bearer = try await authService.bearerToken(forceRefresh: true)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        continue
      }
      if status == 429 {
        let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        if thumbnailRateLimitedUntil.map({ $0 <= Date() }) ?? true {
          let delay = min(max(thumbnailRateLimitDelay, retryAfter ?? 0), Self.thumbnailRateLimitMaxDelay)
          thumbnailRateLimitedUntil = Date().addingTimeInterval(delay)
          thumbnailRateLimitDelay = min(thumbnailRateLimitDelay * 2, Self.thumbnailRateLimitMaxDelay)
        }
        continue
      }
      if let status, (200...299).contains(status) {
        thumbnailRateLimitedUntil = nil
        thumbnailRateLimitDelay = Self.thumbnailRateLimitBaseDelay
      }
      return (data, response)
    }
  }

  /// Headers for media fetched outside this client (video streams and downloads).
  public func mediaHeaders() async throws -> [String: String] {
    let token = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    return ["Authorization": "Bearer \(token)", "User-Agent": device.photosUserAgent(languageCode: language)]
  }

  /// Downloads `url` (a download link or stream) to a temporary file.
  public func download(_ url: URL) async throws -> URL {
    // Asked for by the person looking at the item, so cellular is theirs to use.
    let request = try await mediaRequest(url)
    let (file, response) = try await uploadSession.download(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw GPhotosError.httpError(status: http.statusCode, body: "")
    }
    return file
  }

  private func mediaRequest(_ url: URL) async throws -> URLRequest {
    var request = URLRequest(url: url)
    for (field, value) in try await mediaHeaders() { request.setValue(value, forHTTPHeaderField: field) }
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func libraryRPC(
    _ url: URL, body: Data, extensionHeaders: Bool = true, isAction: Bool = false
  ) async throws -> Data {
    let token = try await authService.bearerToken()
    let language = await authService.credentialLanguage()
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    applyCommonHeaders(&request, bearer: token, language: language)
    if extensionHeaders {
      request.setValue(GPhotosEndpoints.commitHeader173412678, forHTTPHeaderField: "x-goog-ext-173412678-bin")
      request.setValue(GPhotosEndpoints.commitHeader174067345, forHTTPHeaderField: "x-goog-ext-174067345-bin")
    }
    request.httpBody = body
    let (data, response) = try await performData(request, retriesTransportFailures: !isAction, isBrowsing: true)
    try validateHTTP(response: response, data: data)
    return data
  }

  // MARK: - Helpers

  private func applyCommonHeaders(_ request: inout URLRequest, bearer: String, language: String) {
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue(device.photosUserAgent(languageCode: language), forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(language, forHTTPHeaderField: "Accept-Language")
  }

  private static let metadataBackoff = Backoff(baseDelay: 1, maxDelay: 30, maxRetries: 4)

  /// Failures raised before any byte of the request reached the server.
  private static let connectionFailuresBeforeSend: Set<URLError.Code> = [
    .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
  ]

  /// Holds the caller until the account's rate-limit wait is over.
  private func waitForRateLimit() async throws {
    guard let until = rateLimitedUntil, until > Date() else { return }
    rateLimitWaiters += 1
    if rateLimitWaiters == 1 { reportRateLimited(true) }
    defer {
      rateLimitWaiters -= 1
      if rateLimitWaiters == 0 { reportRateLimited(false) }
    }
    while let until = rateLimitedUntil, until > Date() {
      try await Task.sleep(for: .seconds(min(Self.rateLimitMaxDelay, max(0, until.timeIntervalSinceNow))))
    }
  }

  /// Starts (or joins) the account-wide wait after a 429, then waits it out. A 429 that
  /// lands while a wait is already running joins it rather than doubling it again; the next
  /// wait doubles up to ten minutes and a success resets it. `Retry-After` is honoured when
  /// Google sends a longer one.
  private func waitOutRateLimit(after response: HTTPURLResponse) async throws {
    let now = Date()
    if rateLimitedUntil.map({ $0 <= now }) ?? true {
      let header = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
      let retryAfter = header.isFinite ? header : 0
      rateLimitedUntil = now.addingTimeInterval(max(rateLimitDelay, retryAfter))
      rateLimitDelay = min(rateLimitDelay * 2, Self.rateLimitMaxDelay)
    }
    try await waitForRateLimit()
  }

  private func noteRequestSucceeded() {
    if rateLimitedUntil.map({ $0 <= Date() }) ?? false {
      rateLimitedUntil = nil
      rateLimitDelay = Self.rateLimitBaseDelay
    }
  }

  /// Retries 5xx and transient transport failures with a short backoff, waits out 429s with
  /// every other request of the account, and returns any other status for the caller to
  /// validate. Cancellation surfaces through `Task.sleep`. `.timedOut` is final because the
  /// session already waited for connectivity. A request that must not run twice passes
  /// `retriesTransportFailures: false` and is retried only on 429, 503 and connection
  /// failures before anything was sent. The Use Cellular Data setting is about uploads:
  /// `isBrowsing` requests (the library, its thumbnails, streams and actions) use whatever
  /// network there is, or the Library would show grey cells and a spinner on cellular.
  private func performData(
    _ request: URLRequest,
    retriesTransportFailures: Bool = true,
    isBrowsing: Bool = false
  ) async throws -> (Data, URLResponse) {
    var request = request
    request.allowsExpensiveNetworkAccess = isBrowsing || allowsExpensiveNetworkAccess
    var attempt = 0
    var rateLimitWaits = 0
    var refreshedAuth = false
    while true {
      try await waitForRateLimit()
      do {
        let (data, response) = try await dataSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        // A token can be revoked before its expiry; one forced refresh recovers it.
        if status == 401 || status == 403, !refreshedAuth,
          request.value(forHTTPHeaderField: "Authorization") != nil
        {
          refreshedAuth = true
          let bearer = try await authService.bearerToken(forceRefresh: true)
          request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
          continue
        }
        if status == 429, let http = response as? HTTPURLResponse, rateLimitWaits < Self.rateLimitMaxWaits {
          rateLimitWaits += 1
          try await waitOutRateLimit(after: http)
          continue
        }
        if let status,
          retriesTransportFailures
            ? status != 429 && GPhotosError.httpError(status: status, body: "").isRetryable
            : status == 503,
          Self.metadataBackoff.shouldRetry(attempt: attempt)
        {
          try await Task.sleep(for: .seconds(Self.metadataBackoff.delay(forAttempt: attempt)))
          attempt += 1
          continue
        }
        if let status, (200...299).contains(status) { noteRequestSucceeded() }
        return (data, response)
      } catch let error as URLError {
        let mapped = GPhotosError.from(urlError: error)
        let retryable =
          retriesTransportFailures
          ? mapped.isRetryable && error.code != .timedOut
          : Self.connectionFailuresBeforeSend.contains(error.code)
        guard retryable, Self.metadataBackoff.shouldRetry(attempt: attempt) else { throw mapped }
        try await Task.sleep(for: .seconds(Self.metadataBackoff.delay(forAttempt: attempt)))
        attempt += 1
      }
    }
  }

  private func validateHTTP(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw GPhotosError.httpError(status: -1, body: "No HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      try Self.throwHTTPError(status: http.statusCode, data: data)
    }
  }

  /// A failed response as an error. `RESOURCE_EXHAUSTED` outside a 429 is the account
  /// running out of storage; a 429 shares that code but only means "slow down".
  static func throwHTTPError(status: Int, data: Data) throws -> Never {
    if status != 429, GooglePhotosMessages.decodeRPCStatus(data)?.code == GooglePhotosMessages.RPCStatus.resourceExhausted {
      throw GPhotosError.storageFull
    }
    throw GPhotosError.httpError(status: status, body: GooglePhotosMessages.errorDetail(data))
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
    if let size = values.fileSize {
      return Int64(size)
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attrs[.size] as? NSNumber {
      return size.int64Value
    }
    throw GPhotosError.fileReadFailed("Cannot determine file size for \(url.lastPathComponent)")
  }
}
