import SwiftUI
import WebKit

/// What the user handed over: Google's `oauth_token` cookie, or a full credential string
/// (`Email=…&Token=…`) exported from another client.
public enum GoogleCredentialInput: Equatable, Sendable {
  case oauthToken(String)
  case credentialString(String)

  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("Email="), trimmed.contains("Token=") || trimmed.contains("androidId=") {
      self = .credentialString(trimmed)
    } else {
      self = .oauthToken(trimmed)
    }
  }

  /// Whether pasted text plausibly is a credential, so a stray clipboard is rejected early.
  static func looksLikeCredential(_ text: String) -> Bool {
    text.hasPrefix("oauth2_4/") || text.contains("oauth_token=") || text.contains("Email=")
      || text.contains("Token=") || text.contains("androidId=")
  }
}

// MARK: - Sheet

/// Connects a Google account. Sized to its content on every platform.
public struct WebAuthSheet: View {
  public enum Method: String, CaseIterable, Identifiable {
    case google
    case token

    public var id: Self { self }

    var title: LocalizedStringKey {
      switch self {
      case .google: "Sign in with Google"
      case .token: "Paste a Token"
      }
    }
  }

  private let onCredential: (GoogleCredentialInput) async throws -> Void
  private let onCancel: () -> Void

  @State private var method: Method
  @State private var token = ""
  @State private var errorMessage: String?
  @State private var isConnecting = false
  @State private var isPageLoading = true
  @State private var showsTokenHelp = false
  @State private var connection: Task<Void, Never>?
  @State private var webSessionID = UUID()
  @State private var didFinish = false
  @State private var containerHeight: CGFloat = 0
  #if os(macOS)
    @State private var sheetHeight: CGFloat = 0
  #endif
  @ScaledMetric(relativeTo: .footnote) private var stepSize: CGFloat = 22
  @FocusState private var tokenFieldFocused: Bool
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Bounds a hung network call: dismissal is disabled while connecting, so without it a
  /// stalled request would leave the sheet with no way out.
  private static let connectTimeout: Duration = .seconds(45)

  public init(
    onCredential: @escaping (GoogleCredentialInput) async throws -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onCredential = onCredential
    self.onCancel = onCancel
    #if os(iOS)
      _method = State(initialValue: .google)
    #else
      // Google often refuses embedded sign-in on macOS, so the browser route leads.
      _method = State(initialValue: .token)
    #endif
    #if DEBUG
      if UserDefaults.standard.string(forKey: "UIScreen") == "signInGoogle" { _method = State(initialValue: .google) }
    #endif
  }

  public var body: some View {
    layout
      .onChange(of: errorMessage) { _, message in
        if let message { AccessibilityNotification.Announcement(message).post() }
      }
      .onChange(of: method) {
        errorMessage = nil
        webSessionID = UUID()
      }
      .onDisappear {
        // A swipe-dismissal is a cancel too. While connecting, the presenter is closing the
        // sheet because the account was just added, so that is not a cancel.
        guard !didFinish, !isConnecting else { return }
        didFinish = true
        onCancel()
      }
  }

  @ViewBuilder
  private var layout: some View {
    #if os(iOS)
      // One structural tree for both methods: swapping branches would tear `content` down
      // and read as a dismissal. In Google mode the page fills the sheet and scrolls itself.
      ScrollView {
        content
          .padding(.horizontal, 20)
          .padding(.top, 12)
          .padding(.bottom, 20)
          .frame(height: method == .google && containerHeight > 0 ? containerHeight : nil, alignment: .top)
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollDisabled(method == .google)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
      .presentationDetents([.large])
      .presentationDragIndicator(.hidden)
      .interactiveDismissDisabled(isConnecting)
    #else
      VStack(spacing: 0) {
        content
          .padding(20)
        Divider()
        HStack {
          Button("Cancel", action: cancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isConnecting)
          Label("Stored only in this Mac’s Keychain.", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
          Spacer()
          if method == .token {
            connectButton
              .keyboardShortcut(.defaultAction)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
      .frame(width: 480)
      .defaultFocus($tokenFieldFocused, true)
      // A presented Mac sheet keeps its first size, so it is resized to each method's
      // natural height rather than reserving the tallest one up front.
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
      .background(SheetHeightMatcher(height: sheetHeight, animated: !reduceMotion))
      .frame(maxHeight: .infinity, alignment: .top)
      .presentationSizing(.fitted)
      .interactiveDismissDisabled(isConnecting)
      #if DEBUG
        .task {
          // Exercises the sheet resizing between methods for UI review.
          guard UserDefaults.standard.string(forKey: "UIScreen") == "signInSwitch" else { return }
          try? await Task.sleep(for: .seconds(2))
          method = .google
        }
      #endif
    #endif
  }

  private var content: some View {
    VStack(spacing: 20) {
      header
      Picker("Sign-in method", selection: $method) {
        ForEach(Method.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(isConnecting)

      methodContent

      #if os(iOS)
        Label("Your credential is stored only in this device’s Keychain.", systemImage: "lock.fill")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      #endif
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: method)
    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: errorMessage)
    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsTokenHelp)
  }

  private var methodContent: some View {
    VStack(spacing: 16) {
      Group {
        switch method {
        case .google: googleSignIn
        case .token: tokenEntry
        }
      }
      .transition(.opacity)

      if let message = errorMessage {
        InlineMessage(message)
          .transition(.opacity.combined(with: .move(edge: .top)))
        if method == .google, !isConnecting {
          Button("Reload Sign-In Page", systemImage: "arrow.clockwise") {
            errorMessage = nil
            webSessionID = UUID()
          }
          .buttonStyle(.glass)
        }
      }
    }
  }

  private var header: some View {
    VStack(spacing: 12) {
      #if os(iOS)
        HStack {
          Spacer()
          Button("Cancel", systemImage: "xmark", action: cancel)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(isConnecting)
        }
        VStack(spacing: 12) {
          appIcon(size: 60)
          VStack(spacing: 6) {
            title
            subtitle
              .multilineTextAlignment(.center)
          }
        }
      #else
        // Compact on the Mac so the embedded Google page fits in the window's sheet.
        HStack(spacing: 14) {
          appIcon(size: 44)
          VStack(alignment: .leading, spacing: 2) {
            title
            if method == .token { subtitle }
          }
          Spacer(minLength: 0)
        }
      #endif
    }
  }

  /// The Google Photos logo on a white tile, as in the account sheet. The asset lives in
  /// the app's shared asset catalog, so it loads from the main bundle.
  private func appIcon(size: CGFloat) -> some View {
    Image("GooglePhotosLogo", bundle: .main)
      .resizable()
      .scaledToFit()
      .frame(width: size * 0.66, height: size * 0.66)
      .frame(width: size, height: size)
      .background {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
          .fill(.white)
          .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
      }
      .accessibilityHidden(true)
  }

  private var title: some View {
    Text("Connect Google Photos")
      .font(.title2.weight(.semibold))
      .accessibilityAddTraits(.isHeader)
  }

  private var subtitle: some View {
    Text("Photos and videos back up to your Google account in original quality.")
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Sign in with Google

  private var googleSignIn: some View {
    VStack(spacing: 10) {
      let sessionID = webSessionID
      EmbeddedSignInView(
        url: GPhotosEndpoints.embeddedSetup,
        onToken: { token in
          guard !isConnecting, !didFinish, sessionID == webSessionID else { return }
          connect(with: token)
        },
        onLoadingChanged: { isPageLoading = $0 },
        onError: { errorMessage = $0 }
      )
      .id(webSessionID)
      #if os(iOS)
        .frame(minHeight: 360, maxHeight: .infinity)
      #else
        .frame(height: 360)
      #endif
      .clipShape(.rect(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.separator)
      }
      .overlay {
        if isPageLoading || isConnecting {
          VStack(spacing: 10) {
            ProgressView()
            Text(isConnecting ? "Connecting…" : "Loading Google sign-in…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(20)
          .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        }
      }

      Button {
        method = .token
      } label: {
        Text("Blocked by Google? Use **Paste\u{00A0}a\u{00A0}Token**.")
          .font(.footnote)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(isConnecting)
    }
  }


  // MARK: Paste a token

  private var tokenEntry: some View {
    VStack(alignment: .leading, spacing: 16) {
      step(1, "Sign in to Google in your browser.") {
        Button("Open Google Sign-In", systemImage: "arrow.up.forward.app") {
          openURL(GPhotosEndpoints.embeddedSetup)
        }
        .buttonStyle(.glass)
        .disabled(isConnecting)
      }

      step(2, "Copy the value of the oauth_token cookie.") {
        VStack(alignment: .leading, spacing: 6) {
          Button {
            showsTokenHelp.toggle()
          } label: {
            HStack(spacing: 4) {
              Text("Where do I find it?")
              Image(systemName: "chevron.right")
                .rotationEffect(.degrees(showsTokenHelp ? 90 : 0))
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityValue(showsTokenHelp ? "Expanded" : "Collapsed")
          if showsTokenHelp {
            Text(Self.tokenHelp)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      step(3, "Paste it here.") {
        HStack(spacing: 8) {
          SecureField("oauth2_4/…", text: $token)
            .font(.body.monospaced())
            .focused($tokenFieldFocused)
            .submitLabel(.go)
            .onSubmit(submitToken)
            .onChange(of: token) { errorMessage = nil }
            .disabled(isConnecting)
            .accessibilityLabel("Google token")
            #if os(iOS)
              .padding(.horizontal, 14)
              .frame(minHeight: 44)
              .background(.fill.tertiary, in: .capsule)
            #else
              .textFieldStyle(.roundedBorder)
            #endif
          PasteButton(payloadType: String.self) { strings in
            paste(strings.first ?? "")
          }
          .labelStyle(.iconOnly)
          .buttonBorderShape(.circle)
          #if os(iOS)
            .controlSize(.large)
          #endif
          .disabled(isConnecting)
        }
      }

      #if os(iOS)
        connectButton
          .padding(.top, 4)
      #endif
    }
  }

  #if os(iOS)
    private static let tokenHelp: LocalizedStringKey =
      "Use a computer: sign in there, open the browser’s developer tools, choose Application (or Storage) › Cookies › accounts.google.com, and copy the oauth_token value. It starts with “oauth2_4/”. Send it to this iPhone with Universal Clipboard or AirDrop."
  #else
    private static let tokenHelp: LocalizedStringKey =
      "Open the browser’s developer tools, choose Application (or Storage) › Cookies › accounts.google.com, and copy the oauth_token value. It starts with “oauth2_4/”."
  #endif

  private func step<Content: View>(
    _ number: Int, _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(number, format: .number)
        .font(.footnote.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: stepSize, height: stepSize)
        .background(Color.accentColor, in: .circle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.subheadline.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        content()
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var connectButton: some View {
    Button(action: submitToken) {
      HStack(spacing: 8) {
        if isConnecting {
          ProgressView()
            .controlSize(.small)
        }
        Text(isConnecting ? "Connecting…" : "Connect")
      }
      #if os(iOS)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 30)
      #endif
    }
    .buttonStyle(.glassProminent)
    #if os(iOS)
      .controlSize(.large)
    #endif
    .disabled(GoogleCredentialInput(token) == nil || isConnecting)
  }

  // MARK: Actions

  private func paste(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard GoogleCredentialInput.looksLikeCredential(trimmed) else {
      errorMessage = String(localized: "The clipboard doesn’t contain a Google token.")
      return
    }
    token = trimmed
    errorMessage = nil
    tokenFieldFocused = true
  }

  private func submitToken() {
    connect(with: token)
  }

  private func connect(with text: String) {
    guard let credential = GoogleCredentialInput(text), !isConnecting, !didFinish else { return }
    isConnecting = true
    errorMessage = nil
    let attempt = Task { @MainActor in
      do {
        try await onCredential(credential)
        didFinish = true
        token = ""
      } catch {
        // Only the timeout below cancels this task; the sheet can't be closed mid-connect.
        fail(
          Task.isCancelled
            ? String(localized: "Google didn’t respond in time. Check your connection and try again.")
            : error.localizedDescription)
      }
      isConnecting = false
    }
    connection = attempt
    Task { @MainActor in
      try? await Task.sleep(for: Self.connectTimeout)
      if isConnecting, connection == attempt { attempt.cancel() }
    }
  }

  private func fail(_ message: String) {
    // Rebuild the web view first: its reload reports loading state, and the message
    // explaining the failure must survive that.
    webSessionID = UUID()
    errorMessage = message
    if method == .token { tokenFieldFocused = true }
  }

  private func cancel() {
    guard !isConnecting, !didFinish else { return }
    didFinish = true
    connection?.cancel()
    onCancel()
  }
}

// MARK: - Embedded sign-in

/// Watches Google's embedded setup page for the `oauth_token` cookie it sets on success.
@MainActor
private final class EmbeddedSignInCoordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
  var onToken: (String) -> Void
  var onLoadingChanged: (Bool) -> Void
  var onError: (String) -> Void
  private weak var cookieStore: WKHTTPCookieStore?
  private var hasDetectedToken = false
  private var isOnGooglePage = false

  init(
    onToken: @escaping (String) -> Void,
    onLoadingChanged: @escaping (Bool) -> Void,
    onError: @escaping (String) -> Void
  ) {
    self.onToken = onToken
    self.onLoadingChanged = onLoadingChanged
    self.onError = onError
  }

  func makeWebView(url: URL) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    #if os(macOS)
      webView.pageZoom = 0.72
    #endif
    webView.navigationDelegate = self
    let store = configuration.websiteDataStore.httpCookieStore
    cookieStore = store
    store.add(self)
    webView.load(URLRequest(url: url))
    return webView
  }

  func tearDown() {
    cookieStore?.remove(self)
    cookieStore = nil
  }

  /// Sign-in only ever needs Google's own hosts; anything else is refused so the token
  /// page cannot be navigated somewhere unexpected.
  static func isGoogleHost(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
    return host == "google.com" || host.hasSuffix(".google.com")
  }

  nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    Task { @MainActor in self.checkCookies() }
  }

  private func checkCookies() {
    guard !hasDetectedToken, isOnGooglePage, let store = cookieStore else { return }
    Task {
      let now = Date()
      let cookies = await store.allCookies()
      guard !hasDetectedToken,
        let cookie = cookies.first(where: { cookie in
          let domain = cookie.domain.lowercased()
          return cookie.name == "oauth_token" && !cookie.value.isEmpty && cookie.isSecure && cookie.path == "/"
            && (domain == "google.com" || domain.hasSuffix(".google.com"))
            && (cookie.expiresDate.map { $0 > now } ?? true)
        })
      else { return }
      hasDetectedToken = true
      await store.deleteCookie(cookie)
      onToken(cookie.value)
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    // Only the page itself is restricted; Google's sign-in embeds blank and helper frames.
    guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
    guard let url = navigationAction.request.url, Self.isGoogleHost(url) else { return .cancel }
    return .allow
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    onLoadingChanged(true)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onLoadingChanged(false)
    isOnGooglePage = webView.url.map(Self.isGoogleHost) ?? false
    checkCookies()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    handle(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handle(error)
  }

  private func handle(_ error: Error) {
    onLoadingChanged(false)
    let error = error as NSError
    // Redirects and refused navigations cancel loads routinely; they are not failures.
    let isCancellation =
      (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
      || (error.domain == "WebKitErrorDomain" && error.code == 102)
    guard !isCancellation else { return }
    onError(error.localizedDescription)
  }
}

#if os(iOS)
  private struct EmbeddedSignInView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void
    let onLoadingChanged: (Bool) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> EmbeddedSignInCoordinator {
      EmbeddedSignInCoordinator(onToken: onToken, onLoadingChanged: onLoadingChanged, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
      context.coordinator.makeWebView(url: url)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
      context.coordinator.onToken = onToken
      context.coordinator.onLoadingChanged = onLoadingChanged
      context.coordinator.onError = onError
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: EmbeddedSignInCoordinator) {
      coordinator.tearDown()
    }
  }
#else
  /// Resizes the sheet window that hosts it, keeping the top edge where it is.
  private struct SheetHeightMatcher: NSViewRepresentable {
    let height: CGFloat
    let animated: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
      guard height > 0 else { return }
      // The window is attached after the first layout pass.
      DispatchQueue.main.async {
        guard let window = view.window, window.isSheet else { return }
        let current = window.contentRect(forFrameRect: window.frame).height
        guard abs(current - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y -= height - current
        frame.size.height += height - current
        window.setFrame(frame, display: true, animate: animated)
      }
    }
  }

  private struct EmbeddedSignInView: NSViewRepresentable {
    let url: URL
    let onToken: (String) -> Void
    let onLoadingChanged: (Bool) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> EmbeddedSignInCoordinator {
      EmbeddedSignInCoordinator(onToken: onToken, onLoadingChanged: onLoadingChanged, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
      context.coordinator.makeWebView(url: url)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      context.coordinator.onToken = onToken
      context.coordinator.onLoadingChanged = onLoadingChanged
      context.coordinator.onError = onError
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: EmbeddedSignInCoordinator) {
      coordinator.tearDown()
    }
  }
#endif
