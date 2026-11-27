import SwiftUI
import WebKit

struct GooglePhotosWebSheet: View {
  enum Mode {
    case signIn, manage
  }

  let library: CloudLibrary
  let mode: Mode
  let onSignIn: () -> Void
  @State private var page: WebPage?
  @State private var needsSignIn = false
  @State private var showsPage = false
  @State private var error: String?
  @State private var attempt = 0
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  private var isSigningIn: Bool { mode == .signIn || needsSignIn }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if isSigningIn {
          Text("Sign in to Google Photos on the web to use your Locked Folder.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        ZStack {
          if let page {
            let visible = showsPage && (mode == .signIn || scenePhase == .active)
            WebView(page)
              .webViewLinkPreviews(.disabled)
              .opacity(visible ? 1 : 0)
              .disabled(!visible)
              .allowsHitTesting(visible)
              .accessibilityHidden(!visible)
          }
          if let error {
            ContentUnavailableView {
              Label("Couldn’t Open Google Photos", systemImage: "exclamationmark.circle")
            } description: {
              Text(error)
            } actions: {
              Button("Try Again") { attempt += 1 }
                .buttonStyle(.glass)
            }
          } else if !showsPage {
            ProgressView("Opening Google Photos…")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
      }
      .navigationTitle(isSigningIn ? "Sign In to Google Photos" : "Manage Locked Folder")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(isSigningIn ? "Cancel" : "Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 540, idealWidth: 720, minHeight: 560, idealHeight: 660)
    #else
      .presentationDetents([.large])
    #endif
    .task(id: attempt) { await open() }
    .onChange(of: library.isRetired) { _, retired in if retired { dismiss() } }
    .onChange(of: scenePhase) { _, phase in
      if mode == .manage, phase == .background { dismiss() }
    }
  }

  private func open() async {
    guard !library.isRetired else { return }
    error = nil
    showsPage = false
    page = nil
    let session = GooglePhotosWebSession(accountEmail: library.accountEmail)
    let store = WKWebsiteDataStore.nonPersistent()
    do {
      let signingIn = isSigningIn
      let webPage =
        if signingIn {
          session.makePage(store: store)
        } else {
          try await session.makeSignedInPage()
        }
      try Task.checkCancellation()
      page = webPage
      defer { webPage.stopLoading() }
      var navigations = webPage.navigations
      _ = webPage.load(signingIn ? session.signInURL : GooglePhotosWebSession.lockedFolderURL)
      while true {
        do {
          for try await event in navigations {
            try Task.checkCancellation()
            switch event {
            case .committed:
              showsPage = false
            case .finished:
              // Sign-in and re-authentication pass through other Google pages first.
              guard webPage.url?.host()?.lowercased() == GooglePhotosWebSession.libraryURL.host() else {
                showsPage = true
                continue
              }
              if signingIn {
                try await library.saveLockedFolderSignIn(from: store, page: webPage)
                guard !Task.isCancelled, !library.isRetired else { return }
                if mode == .signIn {
                  onSignIn()
                  dismiss()
                } else {
                  needsSignIn = false
                  attempt += 1
                }
                return
              }
              try await session.verifyAccount(on: webPage)
              showsPage = true
            default: break
            }
          }
          return
        } catch let error where Self.isCancelledNavigation(error) {
          // A refused link or download, or a redirect: the current page stays.
          if webPage.url != nil { showsPage = true }
          navigations = webPage.navigations
        }
      }
    } catch is CancellationError {
    } catch let error as GooglePhotosWebError
      where
      !isSigningIn && (error == .signInRequired || error == .wrongAccount)
    {
      needsSignIn = true
      attempt += 1
    } catch {
      self.error = (error as? GooglePhotosWebError ?? .unavailable).localizedDescription
      showsPage = false
    }
  }

  private static func isCancelledNavigation(_ error: Error) -> Bool {
    var underlying = error
    if case WebPage.NavigationError.failedProvisionalNavigation(let inner) = error { underlying = inner }
    let error = underlying as NSError
    return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
      || (error.domain == "WebKitErrorDomain" && error.code == 102)
  }
}
