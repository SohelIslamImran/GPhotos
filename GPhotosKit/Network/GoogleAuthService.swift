import Foundation
import Security

public actor GoogleAuthService {
  private let device: DeviceProfile = .metered
  private var cachedToken: String?
  private var cachedExpiry: Date?
  private var credentialQuery: String?
  /// Bumped whenever the credential changes, so a refresh that finishes afterwards
  /// cannot cache a token minted for the previous credential.
  private var credentialGeneration = 0
  private var refreshTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var refreshWaiters: [UUID: CheckedContinuation<String, any Error>] = [:]

  struct InstalledCredential: Equatable, Sendable {
    let email: String
    let generation: Int
  }

  var installedCredential: InstalledCredential? {
    guard let query = credentialQuery, let email = Self.parseEmail(from: query) else { return nil }
    return InstalledCredential(email: email, generation: credentialGeneration)
  }

  struct AuthToken: Sendable {
    let token: String
    let expiry: Date
  }

  private static let strippedKeys: Set<String> = [
    "it_caveat_types",
    "assertion_jwt",
  ]

  /// No cookies or cache: each account's auth traffic stays separate, as on separate devices.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
  }()

  private let fetch: @Sendable (URLRequest, TokenBindingSession?) async throws -> AuthToken

  public init() {
    fetch = Self.fetchToken
  }

  init(fetch: @escaping @Sendable (URLRequest, TokenBindingSession?) async throws -> AuthToken) {
    self.fetch = fetch
  }

  // MARK: - Credential Configuration

  public func setCredential(_ raw: String, expectedEmail: String? = nil) throws {
    do {
      let sanitized = try Self.sanitizedCredentialQuery(from: raw)
      if let expectedEmail, Self.parseEmail(from: sanitized) != expectedEmail {
        throw GPhotosError.invalidCredential("Credential and account do not match")
      }
      replaceCredential(sanitized)
    } catch {
      clearCredential()
      throw error
    }
  }

  func clearCredential() {
    replaceCredential(nil)
  }

  public func credentialLanguage() -> String {
    guard let query = credentialQuery else { return "en_US" }
    let items = FormURLEncoding.decode(query)
    if let lang = items.first(where: { $0.name == "lang" })?.value, !lang.isEmpty {
      return lang
    }
    return "en_US"
  }

  private func replaceCredential(_ query: String?) {
    credentialQuery = query
    cachedToken = nil
    cachedExpiry = nil
    credentialGeneration += 1
    refreshTask?.cancel()
    if let refreshID { finishRefresh(refreshID, result: .failure(GPhotosError.notAuthenticated)) }
  }

  public func accounts() throws -> [GoogleAccount] {
    try KeychainStore.loadAccounts().accounts
  }

  /// Every account and the one in use, from a single keychain read.
  public func accountsAndSelection() throws -> (accounts: [GoogleAccount], selected: GoogleAccount?) {
    let (accounts, primaryEmail) = try KeychainStore.loadAccounts()
    return (accounts, accounts.first { $0.email == primaryEmail } ?? accounts.first)
  }

  public func signOut() throws {
    try KeychainStore.deleteAccounts()
    clearCredential()
  }

  // MARK: - Embedded Setup Authentication Flow

  /// Exchanges an Embedded Setup oauth_token cookie value for a master token and constructs the full Google Photos credential.
  @discardableResult
  public func addAccountFromOAuthToken(_ rawToken: String) async throws -> GoogleAccount {
    let oauthToken = try Self.normalizeOAuthToken(rawToken)
    let androidId = try Self.generateAndroidId()

    let (email, masterToken) = try await exchangeEmbeddedSetupToken(
      oauthToken: oauthToken,
      androidId: androidId
    )

    let credential = Self.buildGooglePhotosCredential(
      email: email,
      masterToken: masterToken,
      androidId: androidId
    )
    let account = GoogleAccount(email: email, androidId: androidId, credentialString: credential)
    try await activate(account)
    return account
  }

  /// Adds an account using a pre-captured Android query string (e.g. from ADB / ReVanced).
  @discardableResult
  public func addAccountWithRawCredential(_ rawCredential: String) async throws -> GoogleAccount {
    let sanitized = try Self.sanitizedCredentialQuery(from: rawCredential)
    let email = Self.parseEmail(from: sanitized) ?? "user@gmail.com"
    let androidId = try Self.parseAndroidId(from: sanitized) ?? Self.generateAndroidId()
    let account = GoogleAccount(email: email, androidId: androidId, credentialString: sanitized)
    try await activate(account)
    return account
  }

  /// Validate on a separate service so the primary client's credential never changes
  /// until the app has drained its outgoing account work.
  private func activate(_ account: GoogleAccount) async throws {
    let probe = GoogleAuthService()
    try await probe.setCredential(account.credentialString, expectedEmail: account.email)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try await probe.bearerToken()
        try await probe.verifyPhotosAccess()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw GPhotosError.from(urlError: URLError(.timedOut))
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    try KeychainStore.saveAccount(account)
  }

  /// Checks that the account has Google Photos access before saving its credential.
  private func verifyPhotosAccess() async throws {
    let probe = GooglePhotosMobileClient(authService: self, isolatedSession: true)
    do {
      _ = try await probe.findExisting(sha1: Data(count: 20))
    } catch GPhotosError.httpError(let status, _) where status == 401 || status == 403 {
      throw GPhotosError.photosUnavailable
    }
  }

  // MARK: - Bearer Token Resolution & Refresh

  public func bearerToken(forceRefresh: Bool = false) async throws -> String {
    try Task.checkCancellation()
    if !forceRefresh, let token = cachedToken, let expiry = cachedExpiry, expiry > Date().addingTimeInterval(60) {
      return token
    }
    guard let query = credentialQuery else { throw GPhotosError.notAuthenticated }
    let generation = credentialGeneration
    if refreshTask == nil {
      let (request, session) = try makeTokenRequest(query: query)
      let id = UUID()
      refreshID = id
      refreshTask = Task {
        let result: Result<AuthToken, any Error>
        do {
          result = .success(try await self.fetch(request, session))
        } catch {
          result = .failure(error)
        }
        self.finishRefresh(id, result: result)
      }
    }
    let id = UUID()
    // Cancel just this caller's wait. A retiring Library must not stay blocked on a
    // refresh that other callers also need.
    let token: String = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { refreshWaiters[id] = $0 }
    } onCancel: {
      Task { await self.cancelRefreshWaiter(id) }
    }
    try Task.checkCancellation()
    guard generation == credentialGeneration else { throw GPhotosError.notAuthenticated }
    return token
  }

  private func cancelRefreshWaiter(_ id: UUID) {
    guard let waiter = refreshWaiters.removeValue(forKey: id) else { return }
    waiter.resume(throwing: CancellationError())
    guard refreshWaiters.isEmpty, let refreshID else { return }
    refreshTask?.cancel()
    finishRefresh(refreshID, result: .failure(CancellationError()))
  }

  private func finishRefresh(_ id: UUID, result: Result<AuthToken, any Error>) {
    guard refreshID == id else { return }
    refreshID = nil
    refreshTask = nil
    if case .success(let fresh) = result {
      cachedToken = fresh.token
      cachedExpiry = fresh.expiry
    }
    let waiters = refreshWaiters.values
    refreshWaiters.removeAll()
    for waiter in waiters { waiter.resume(with: result.map(\.token)) }
  }

  private func makeTokenRequest(
    query: String, service: String? = nil, asGooglePlayServices: Bool = false
  ) throws -> (request: URLRequest, session: TokenBindingSession?) {
    var items = FormURLEncoding.decode(query)
    if let service, let index = items.firstIndex(where: { $0.name == "service" }) {
      items[index].value = service
    }

    items.removeAll { ["app", "callerPkg", "it_caveat_types", "assertion_jwt"].contains($0.name) }
    let app = asGooglePlayServices ? "com.google.android.gms" : "com.google.android.apps.photos"
    items.append(("app", app))
    items.append(("callerPkg", app))
    if asGooglePlayServices {
      for index in items.indices where items[index].name == "client_sig" || items[index].name == "callerSig" {
        items[index].value = "38918a453d07199354f8b19af05ec6562ced5788"
      }
    }

    var session: TokenBindingSession?
    if let aliasIndex = items.firstIndex(where: { $0.name == "token_binding_alias" }) {
      let alias = items[aliasIndex].value
      items.removeAll { $0.name == "token_binding_alias" }
      if !alias.isEmpty {
        let (bindingSession, assertionJWT) = try TokenBindingSession.create(alias: alias)
        session = bindingSession
        items.append(("assertion_jwt", assertionJWT))
      }
    }

    let androidId = items.first(where: { $0.name == "androidId" })?.value ?? ""
    var request = URLRequest(url: GPhotosEndpoints.auth)
    request.httpMethod = "POST"
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(app, forHTTPHeaderField: "app")
    request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(androidId, forHTTPHeaderField: "device")
    request.setValue(device.authUserAgent(), forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(FormURLEncoding.encode(items).utf8)
    return (request, session)
  }

  private static func fetchToken(_ request: URLRequest, session: TokenBindingSession?) async throws -> AuthToken {
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await Self.session.data(for: request)
    } catch let error as URLError {
      throw GPhotosError.from(urlError: error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw GPhotosError.authFailed(status: -1, body: "No HTTP response")
    }
    var parsed = parseAuthResponse(String(data: data, encoding: .utf8) ?? "")
    if let err = parsed["Error"] {
      throw GPhotosError.authFailed(status: http.statusCode, body: err)
    }
    guard (200...299).contains(http.statusCode) else {
      throw GPhotosError.authFailed(status: http.statusCode, body: "HTTP \(http.statusCode)")
    }

    try TokenBindingSession.decryptTokenEncryptedResponse(&parsed, session: session)

    // The body carries the token itself, so it never goes into the error.
    guard
      let auth = parsed["Auth"], !auth.isEmpty,
      let expiryRaw = parsed["Expiry"], !expiryRaw.isEmpty,
      let expiryUnix = TimeInterval(expiryRaw)
    else {
      throw GPhotosError.authFailed(status: http.statusCode, body: "Unexpected token response")
    }
    return AuthToken(token: auth, expiry: Date(timeIntervalSince1970: expiryUnix))
  }

  // MARK: - Profile Photo

  /// The Photos token has no profile scope and Google refuses that scope to the Photos
  /// client, so the photo is read with a separate short-lived Play services token that is
  /// never cached or used for anything else.
  public func profilePhoto(pixelSize: Int) async throws -> Data? {
    guard let query = credentialQuery else { throw GPhotosError.notAuthenticated }
    let (tokenRequest, binding) = try makeTokenRequest(
      query: query, service: "oauth2:https://www.googleapis.com/auth/userinfo.profile", asGooglePlayServices: true)
    let token = try await Self.fetchToken(tokenRequest, session: binding)

    var infoRequest = URLRequest(url: GPhotosEndpoints.userInfo)
    infoRequest.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
    let (infoData, infoResponse) = try await Self.session.data(for: infoRequest)
    guard (infoResponse as? HTTPURLResponse)?.statusCode == 200,
      let picture = try Self.profilePhotoURL(from: infoData)
    else { return nil }

    let (photo, photoResponse) = try await Self.session.data(
      from: Self.sizedPhotoURL(picture, pixelSize: pixelSize))
    guard (photoResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return photo
  }

  static func profilePhotoURL(from data: Data) throws -> URL? {
    struct UserInfo: Decodable { let picture: String? }
    guard let picture = try JSONDecoder().decode(UserInfo.self, from: data).picture,
      !picture.isEmpty, !picture.contains(where: { $0.isWhitespace }),
      let url = URL(string: picture), url.scheme == "https", let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  /// Google image options belong in the path, before any query or fragment.
  /// Other providers' URLs are used exactly as returned by userinfo.
  static func sizedPhotoURL(_ url: URL, pixelSize: Int) -> URL {
    guard let host = url.host?.lowercased(),
      host.hasSuffix(".googleusercontent.com") || host == "googleusercontent.com",
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    var path = parts.percentEncodedPath
    if let options = path.range(of: "=", options: .backwards) {
      path.removeSubrange(options.lowerBound...)
    }
    parts.percentEncodedPath = "\(path)=s\(max(1, pixelSize))-c"
    return parts.url ?? url
  }

  // MARK: - Internal Exchange Logic

  private func exchangeEmbeddedSetupToken(oauthToken: String, androidId: String) async throws -> (email: String, masterToken: String) {
    let form = FormURLEncoding.encode([
      ("accountType", "HOSTED_OR_GOOGLE"),
      ("Email", "oauth-token@example.com"),
      ("has_permission", "1"),
      ("add_account", "1"),
      ("ACCESS_TOKEN", "1"),
      ("Token", oauthToken),
      ("service", "ac2dm"),
      ("source", "android"),
      ("androidId", androidId),
      ("device_country", "us"),
      ("operatorCountry", "us"),
      ("lang", "en"),
      ("sdk_version", "17"),
      ("google_play_services_version", "240913000"),
      ("client_sig", "38918a453d07199354f8b19af05ec6562ced5788"),
      ("callerSig", "38918a453d07199354f8b19af05ec6562ced5788"),
      ("droidguard_results", "dummy123"),
    ])

    var request = URLRequest(url: GPhotosEndpoints.embeddedSetupAuth)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.httpBody = Data(form.utf8)

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await Self.session.data(for: request)
    } catch let error as URLError {
      throw GPhotosError.from(urlError: error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw GPhotosError.authFailed(status: -1, body: "No HTTP response")
    }
    let body = String(data: data, encoding: .utf8) ?? ""
    let parsed = Self.parseAuthResponse(body)
    if let authError = parsed["Error"] {
      switch authError {
      case "BadAuthentication":
        throw GPhotosError.invalidCredential(
          "The Google token has expired or was already used (oauth_tokens are single-use and short-lived). Please click 'Open Google Sign-In in Browser' to get a fresh token."
        )
      case "NeedsBrowser":
        throw GPhotosError.invalidCredential("Google requires a fresh sign-in in your browser.")
      default:
        throw GPhotosError.authFailed(status: http.statusCode, body: "Google auth error: \(authError)")
      }
    }

    guard (200...299).contains(http.statusCode) else {
      throw GPhotosError.authFailed(status: http.statusCode, body: "Token exchange failed")
    }

    guard let masterToken = parsed["Token"], !masterToken.isEmpty else {
      throw GPhotosError.authFailed(status: http.statusCode, body: "Auth response did not contain master Token")
    }
    guard let email = parsed["Email"], !email.isEmpty else {
      throw GPhotosError.authFailed(status: http.statusCode, body: "Auth response did not contain valid Email")
    }

    return (email, masterToken)
  }

  // MARK: - Helpers

  static func generateAndroidId() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 8)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw GPhotosError.invalidCredential("Could not generate a device identifier (\(status))")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func normalizeOAuthToken(_ raw: String) throws -> String {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("oauth_token=") {
      trimmed = String(trimmed.dropFirst("oauth_token=".count))
    }
    let hasControlCharacter = trimmed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    guard trimmed.count >= 16 && trimmed.count <= 8192 && !hasControlCharacter else {
      throw GPhotosError.invalidCredential("Please provide a valid oauth_token cookie from Google Embedded Setup")
    }
    return trimmed
  }

  static func buildGooglePhotosCredential(email: String, masterToken: String, androidId: String) -> String {
    FormURLEncoding.encode([
      ("androidId", androidId),
      ("app", "com.google.android.apps.photos"),
      ("callerPkg", "com.google.android.apps.photos"),
      ("callerSig", "24bb24c05e47e0aefa68a58a766179d9b613a600"),
      ("client_sig", "24bb24c05e47e0aefa68a58a766179d9b613a600"),
      ("device_country", "us"),
      ("Email", email),
      ("google_play_services_version", "240913000"),
      ("lang", "en_US"),
      ("oauth2_foreground", "1"),
      ("operatorCountry", "us"),
      ("sdk_version", "33"),
      ("service", "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native"),
      ("source", "android"),
      ("Token", masterToken),
    ])
  }

  static func sanitizedCredentialQuery(from raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let query: String
    if trimmed.contains("="), !trimmed.hasPrefix("http") {
      query = trimmed.hasPrefix("?") ? String(trimmed.dropFirst()) : trimmed
    } else if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      query = components.percentEncodedQuery ?? ""
    } else {
      throw GPhotosError.invalidCredential("Unrecognized credential format")
    }

    let filtered = FormURLEncoding.decode(query).filter { !strippedKeys.contains($0.name) }
    guard !filtered.isEmpty else {
      throw GPhotosError.invalidCredential("Credential query is empty after sanitization")
    }
    return FormURLEncoding.encode(filtered)
  }

  static func parseAuthResponse(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in body.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      result[parts[0]] = parts[1]
    }
    return result
  }

  private static func parseEmail(from query: String) -> String? {
    FormURLEncoding.decode(query).first(where: { $0.name == "Email" })?.value
  }

  private static func parseAndroidId(from query: String) -> String? {
    FormURLEncoding.decode(query).first(where: { $0.name == "androidId" })?.value
  }
}

/// `application/x-www-form-urlencoded` bodies. Everything outside the RFC 3986
/// unreserved set is percent-encoded; notably `+`, which a form decoder reads as a space.
enum FormURLEncoding {
  typealias Field = (name: String, value: String)

  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func encode(_ fields: [Field]) -> String {
    fields.map { "\(escape($0.name))=\(escape($0.value))" }.joined(separator: "&")
  }

  static func decode(_ form: String) -> [Field] {
    form.split(separator: "&", omittingEmptySubsequences: true).map { pair in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (unescape(parts[0]), parts.count > 1 ? unescape(parts[1]) : "")
    }
  }

  static func escape(_ string: String) -> String {
    string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
  }

  private static func unescape(_ component: Substring) -> String {
    let spaced = component.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
  }
}
