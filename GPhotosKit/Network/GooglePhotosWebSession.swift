import CryptoKit
import Foundation
import WebKit

enum GooglePhotosWebError: LocalizedError, Equatable {
  case signInRequired
  case wrongAccount
  case rejected
  case unavailable
  case syncPending
  case busy

  var errorDescription: String? {
    switch self {
    case .signInRequired: String(localized: "Sign in to Google Photos on the web and try again.")
    case .wrongAccount: String(localized: "Sign in with the Google account you’re browsing in this app.")
    case .rejected: String(localized: "Google Photos refused the move. Check that you own the items and remove any shared links.")
    case .unavailable: String(localized: "Couldn’t reach Google Photos on the web. Try again.")
    case .syncPending: String(localized: "Wait for Google Photos to finish syncing, then try again.")
    case .busy: String(localized: "Google Photos is busy. Try again in a few minutes.")
    }
  }
}

struct LockedFolderWebRequest {
  static let rpcID = "StLnCe"
  static let listRPC = "nMFwOc"
  static let moveOutRPC = "Pp2Xxe"
  static let batchSize = 100
  static let path = "/_/PhotosUi/"
  private static let componentCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

  let url: URL
  let body: String

  /// The page's endpoint prefix: `/_/PhotosUi/`, or `/u/<n>/_/PhotosUi/` for a second signed-in account.
  static func isValidPath(_ path: String) -> Bool {
    if path == Self.path { return true }
    guard path.hasPrefix("/u/"), path.hasSuffix(Self.path) else { return false }
    let index = path.dropFirst(3).dropLast(Self.path.count)
    return !index.isEmpty && index.allSatisfy(\.isASCII) && index.allSatisfy(\.isNumber)
  }

  init(keys: [String], path: String = Self.path, sourcePath: String, sid: String, build: String, token: String) throws {
    try self.init(rpc: Self.rpcID, payload: [keys, []], path: path, sourcePath: sourcePath, sid: sid, build: build, token: token)
  }

  init(rpc: String, payload: [Any], path: String, sourcePath: String, sid: String, build: String, token: String, rapt: String? = nil) throws
  {
    guard Self.isValidPath(path) else { throw GooglePhotosWebError.unavailable }
    func encode(_ value: String) -> String {
      value.addingPercentEncoding(withAllowedCharacters: Self.componentCharacters) ?? ""
    }

    var parameters = [
      ("rpcids", rpc), ("source-path", sourcePath), ("f.sid", sid), ("bl", build), ("pageId", "none"), ("rt", "c"),
    ]
    if let rapt { parameters.append(("rapt", rapt)) }
    let query = parameters.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    url = URL(string: "https://photos.google.com\(path)data/batchexecute?\(query)")!
    let options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    let data = try JSONSerialization.data(withJSONObject: payload, options: options)
    let envelope = [[[rpc, String(decoding: data, as: UTF8.self), NSNull(), "generic"] as [Any]]]
    let wrapped = try JSONSerialization.data(withJSONObject: envelope, options: options)
    body = "f.req=\(encode(String(decoding: wrapped, as: UTF8.self)))&at=\(encode(token))&"
  }

  static func batches<Item>(of items: [Item]) -> [ArraySlice<Item>] {
    stride(from: 0, to: items.count, by: batchSize).map { items[$0..<min($0 + batchSize, items.count)] }
  }

  static func checkResponse(_ body: String) throws {
    _ = try response(body, rpc: rpcID)
  }

  static func response(_ body: String, rpc: String) throws -> Any {
    for line in body.split(separator: "\n") where line.contains("wrb.fr") {
      guard let entries = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [[Any]] else { continue }
      for entry in entries where entry.count >= 3 && entry[0] as? String == "wrb.fr" && entry[1] as? String == rpc {
        guard let payload = entry[2] as? String,
          let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed]),
          !(value is NSNull)
        else { throw GooglePhotosWebError.rejected }
        return value
      }
    }
    throw GooglePhotosWebError.rejected
  }
}

@MainActor
struct GooglePhotosWebSession {
  static let libraryURL = URL(string: "https://photos.google.com/")!
  static let lockedFolderURL = libraryURL.appending(path: "lockedfolder")
  let accountEmail: String

  var signInURL: URL {
    var url = URLComponents(string: "https://accounts.google.com/AccountChooser")!
    url.queryItems = [
      URLQueryItem(name: "continue", value: Self.libraryURL.absoluteString),
      URLQueryItem(name: "Email", value: accountEmail),
    ]
    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return url.url!
  }

  // Each web page is ephemeral. Only cookies from a verified sign-in are saved.
  private static var cookieDataStores: [UUID: WKWebsiteDataStore] = [:]

  private static func cookieDataStore(for id: UUID) -> WKWebsiteDataStore {
    if let store = cookieDataStores[id] { return store }
    // The cookie-store handle does not retain its owning WebKit data store.
    let store = WKWebsiteDataStore(forIdentifier: id)
    cookieDataStores[id] = store
    return store
  }

  nonisolated static var safariApplicationName: String {
    let version = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
    #if os(iOS)
      return "\(version) Mobile/15E148 Safari/604.1"
    #else
      return "\(version) Safari/605.1.15"
    #endif
  }

  nonisolated static func identifier(for email: String) -> UUID {
    let digest = Array(SHA256.hash(data: Data("GooglePhotosWeb:\(email.lowercased())".utf8)))
    return UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
      ))
  }

  private static func signInKey(for id: UUID) -> String { "GooglePhotosWebSignIn.\(id.uuidString)" }

  static func deleteWebData(forAccountEmail email: String) async {
    let id = identifier(for: email)
    let key = signInKey(for: id)
    guard UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.removeObject(forKey: key)
    // Clear the cookies even if WebKit can't remove the store directory.
    await clearWebData(for: id)
    cookieDataStores[id] = nil
    try? await WKWebsiteDataStore.remove(forIdentifier: id)
  }

  private static func clearWebData(for id: UUID) async {
    let store = cookieDataStore(for: id)
    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
  }

  func makePage(store: WKWebsiteDataStore) -> WebPage {
    var configuration = WebPage.Configuration()
    configuration.websiteDataStore = store
    configuration.allowsAirPlayForMediaPlayback = false
    // Google's web sign-in turns away browsers that don't identify as Safari.
    configuration.applicationNameForUserAgent = Self.safariApplicationName
    return WebPage(configuration: configuration, navigationDecider: GoogleNavigation())
  }

  func makeSignedInDataStore() async throws -> WKWebsiteDataStore {
    let id = Self.identifier(for: accountEmail)
    let key = Self.signInKey(for: id)
    guard UserDefaults.standard.bool(forKey: key) else { throw GooglePhotosWebError.signInRequired }
    let cookies = await Self.cookieDataStore(for: id).httpCookieStore.allCookies()
    guard !cookies.isEmpty else { throw GooglePhotosWebError.signInRequired }
    let store = WKWebsiteDataStore.nonPersistent()
    await store.httpCookieStore.setCookies(cookies)
    return store
  }

  func makeSignedInPage() async throws -> WebPage {
    let store = try await makeSignedInDataStore()
    try Task.checkCancellation()
    let page = makePage(store: store)
    let timeout = Task {
      try await Task.sleep(for: .seconds(25))
      page.stopLoading()
    }
    defer { timeout.cancel() }
    do {
      try await withTaskCancellationHandler {
        for try await event in page.load(URLRequest(url: Self.libraryURL, timeoutInterval: 20)) {
          try Task.checkCancellation()
          if event == .finished { return }
        }
      } onCancel: {
        Task { @MainActor in page.stopLoading() }
      }
      try Task.checkCancellation()
      try await verifyAccount(on: page, waitingUpTo: .seconds(8))
      // Google rotates session cookies; keep the newest so the sign-in lasts.
      let cookies = await store.httpCookieStore.allCookies()
      try Task.checkCancellation()
      let id = Self.identifier(for: accountEmail)
      guard UserDefaults.standard.bool(forKey: Self.signInKey(for: id)) else { throw CancellationError() }
      await replaceSavedCookies(with: cookies, for: id)
      return page
    } catch let error as GooglePhotosWebError {
      page.stopLoading()
      throw error
    } catch is CancellationError {
      page.stopLoading()
      throw CancellationError()
    } catch {
      page.stopLoading()
      if page.url?.host()?.lowercased() == "accounts.google.com" { throw GooglePhotosWebError.signInRequired }
    }
    throw GooglePhotosWebError.unavailable
  }

  private func replaceSavedCookies(with cookies: [HTTPCookie], for id: UUID) async {
    guard !cookies.isEmpty else { return }
    let destination = Self.cookieDataStore(for: id).httpCookieStore
    for cookie in await destination.allCookies() { await destination.deleteCookie(cookie) }
    guard UserDefaults.standard.bool(forKey: Self.signInKey(for: id)) else { return }
    await destination.setCookies(cookies)
  }

  private func evaluate(_ script: String, arguments: [String: Any] = [:], on page: WebPage) async throws -> Any? {
    do {
      return try await page.callJavaScript(script, arguments: arguments, contentWorld: .page)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw GooglePhotosWebError.unavailable
    }
  }

  func verifyAccount(on page: WebPage, waitingUpTo timeout: Duration = .zero) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
      try Task.checkCancellation()
      guard page.url?.host()?.lowercased() == Self.libraryURL.host() else { throw GooglePhotosWebError.signInRequired }
      let account =
        try await evaluate(
          """
          const data = window.WIZ_global_data;
          if (location.origin !== 'https://photos.google.com' || !data?.SNlM0e || typeof data.oPEP7c !== 'string') return '';
          return data.oPEP7c;
          """, on: page) as? String
      if let account, !account.isEmpty {
        guard account.caseInsensitiveCompare(accountEmail) == .orderedSame else { throw GooglePhotosWebError.wrongAccount }
        return
      }
      guard clock.now < deadline else { throw GooglePhotosWebError.signInRequired }
      try await clock.sleep(until: min(deadline, clock.now + .milliseconds(200)))
    }
  }

  func saveSignIn(from store: WKWebsiteDataStore, page: WebPage) async throws {
    // The sign-in redirect can update the URL before the Photos document has its account data.
    try await verifyAccount(on: page, waitingUpTo: .seconds(8))
    let cookies = await store.httpCookieStore.allCookies()
    guard !cookies.isEmpty else { throw GooglePhotosWebError.signInRequired }
    try await verifyAccount(on: page)
    try Task.checkCancellation()
    let id = Self.identifier(for: accountEmail)
    let key = Self.signInKey(for: id)
    UserDefaults.standard.set(true, forKey: key)
    await replaceSavedCookies(with: cookies, for: id)
  }

  /// The caller commits each successful batch before asking to send the next one.
  func moveToLockedFolder(dedupKeys: [String], on page: WebPage) async throws {
    _ = try await send(LockedFolderWebRequest.rpcID, payload: [dedupKeys, []], on: page)
  }

  /// Reads only the selected item's key from Google's reauthenticated folder.
  func moveOutOfLockedFolder(mediaKey: String, on page: WebPage) async throws -> Bool {
    guard
      try await evaluate(
        "return typeof window.WIZ_global_data?.Dbw5Ud === 'string' && !!window.WIZ_global_data.Dbw5Ud;", on: page
      ) as? Bool == true
    else { return false }

    var cursor: String?
    var seen = Set<String>()
    repeat {
      let result = try await send(
        LockedFolderWebRequest.listRPC, payload: [cursor as Any? ?? NSNull()], on: page, requiresReauthentication: true)
      guard let result = result as? [Any], result.count >= 2, let entries = result[1] as? [[Any]]
      else { throw GooglePhotosWebError.rejected }
      if let entry = entries.first(where: { $0.first as? String == mediaKey }),
        entry.count > 3, let key = entry[3] as? String, !key.isEmpty
      {
        _ = try await send(
          LockedFolderWebRequest.moveOutRPC, payload: [[key]], on: page, requiresReauthentication: true)
        return true
      }
      cursor = result[0] as? String
    } while cursor.map({ !$0.isEmpty && seen.insert($0).inserted }) == true
    throw GooglePhotosWebError.rejected
  }

  private func send(_ rpc: String, payload: [Any], on page: WebPage, requiresReauthentication: Bool = false) async throws -> Any {
    try await verifyAccount(on: page)
    let globals =
      try await evaluate(
        """
        const data = window.WIZ_global_data;
        if (!data) return [];
        return [data.eptZe, location.pathname, data.FdrFJe, data.cfb2h, data.SNlM0e, data.Dbw5Ud].map(value => String(value ?? ''));
        """, on: page) as? [String]
    guard let globals, globals.count == 6, globals.prefix(5).allSatisfy({ !$0.isEmpty })
    else { throw GooglePhotosWebError.unavailable }
    let rapt = requiresReauthentication ? globals[5] : ""
    guard !requiresReauthentication || (!rapt.isEmpty && globals[1].split(separator: "/").last == "lockedfolder")
    else { throw GooglePhotosWebError.rejected }
    let request = try LockedFolderWebRequest(
      rpc: rpc, payload: payload, path: globals[0], sourcePath: globals[1], sid: globals[2], build: globals[3],
      token: globals[4], rapt: rapt.isEmpty ? nil : rapt)
    try Task.checkCancellation()
    let result =
      try await evaluate(
        """
        const data = window.WIZ_global_data;
        if (location.origin !== 'https://photos.google.com' || !data?.SNlM0e) return { status: 401 };
        if (data.oPEP7c?.toLowerCase() !== account || data.SNlM0e !== token ||
            (rapt && (data.Dbw5Ud !== rapt || location.pathname !== sourcePath))) return { status: 403 };
        const response = await fetch(url, {
          method: 'POST', credentials: 'include', redirect: 'manual', cache: 'no-store',
          headers: { 'content-type': 'application/x-www-form-urlencoded;charset=UTF-8' },
          body, signal: AbortSignal.timeout(25000)
        });
        return { status: response.status, retryAfter: response.headers.get('Retry-After'), text: await response.text() };
        """,
        arguments: [
          "url": request.url.absoluteString, "body": request.body, "account": accountEmail.lowercased(), "token": globals[4],
          "rapt": rapt, "sourcePath": globals[1],
        ],
        on: page) as? [String: Any]
    switch result?["status"] as? Int {
    case 200:
      return try LockedFolderWebRequest.response(result?["text"] as? String ?? "", rpc: rpc)
    case 0, 401:
      throw GooglePhotosWebError.signInRequired
    case 403:
      // A changed document must pass account verification again before any later send.
      try await verifyAccount(on: page)
      throw GooglePhotosWebError.rejected
    case 429:
      throw WebRateLimit(retryAfter: (result?["retryAfter"] as? String).flatMap(TimeInterval.init) ?? 0)
    default:
      throw GooglePhotosWebError.unavailable
    }
  }

  struct WebRateLimit: Error {
    let retryAfter: TimeInterval
  }

  /// Google's own sign-in hosts. Signing in passes through `accounts.youtube.com` to set its
  /// cookies and may land on a country domain (`www.google.com.my`).
  nonisolated static func isGoogleSignInHost(_ host: String) -> Bool {
    if host == "google.com" || host.hasSuffix(".google.com") || host == "accounts.youtube.com" { return true }
    let labels = host.split(separator: ".").map(String.init)
    guard let index = labels.lastIndex(of: "google") else { return false }
    let suffix = labels[(index + 1)...]
    func isCountry(_ label: String) -> Bool { label.count == 2 && label.allSatisfy { $0.isASCII && $0.isLetter } }
    switch suffix.count {
    case 1: return isCountry(suffix[index + 1])
    case 2: return ["com", "co"].contains(suffix[index + 1]) && isCountry(suffix[index + 2])
    default: return false
    }
  }

  private struct GoogleNavigation: WebPage.NavigationDeciding {
    func decidePolicy(
      for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
      guard !action.shouldPerformDownload else { return .cancel }
      guard action.target?.isMainFrame ?? true else { return .allow }
      return Self.isAllowed(action.request.url) ? .allow : .cancel
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
      let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
      let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true
      return response.canShowMimeType && !isAttachment ? .allow : .cancel
    }

    private static func isAllowed(_ url: URL?) -> Bool {
      guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
      return GooglePhotosWebSession.isGoogleSignInHost(host)
    }
  }
}
