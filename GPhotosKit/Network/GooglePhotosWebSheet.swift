import SwiftUI
import WebKit

struct GooglePhotosWebSheet: View {
  enum Mode {
    case signIn, manage
  }

  let library: CloudLibrary
  let mode: Mode
  var moveOutMediaKey: String?
  var lockedSession: LockedFolderSession?
  var onMoveOutConfirmed: () -> Void = {}
  var onOpenBrowser: () -> Void = {}
  let onSignIn: (WebPage) -> Void
  @State private var page: WebPage?
  @State private var needsSignIn = false
  @State private var showsPage = false
  @State private var error: String?
  @State private var isMovingOut = false
  @State private var didMove = false
  @State private var isUpdatingLibrary = false
  @State private var showsManualInstructions = false
  @State private var attempt = 0
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  private var isSigningIn: Bool { mode == .signIn || needsSignIn }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !didMove { accountHeader }
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
          if didMove {
            if isUpdatingLibrary {
              ProgressView("Updating Library…")
            } else {
              ContentUnavailableView(
                "Moved in Google Photos", systemImage: "checkmark.circle",
                description: Text("The item will appear in your Library when Google Photos finishes syncing."))
            }
          } else if let error {
            ContentUnavailableView {
              Label("Couldn’t Open Google Photos", systemImage: "exclamationmark.circle")
            } description: {
              Text(error)
            } actions: {
              Button("Try Again") { attempt += 1 }
                .buttonStyle(.glass)
            }
          } else if !showsPage {
            ProgressView(isMovingOut ? "Moving Out of Locked Folder…" : "Connecting to Google Photos…")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
      }
      .navigationTitle(
        isSigningIn ? "Sign In to Google Photos" : moveOutMediaKey == nil ? "Manage Locked Folder" : "Move Out of Locked Folder"
      )
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

  private var accountHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(library.accountEmail, systemImage: "person.crop.circle")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      if isSigningIn {
        Text("Sign in with this Google account to let the app move items.")
      } else if showsManualInstructions || (moveOutMediaKey == nil && showsPage) {
        Text("Select your items on the Google Photos page and choose Move.")
      } else if moveOutMediaKey != nil {
        Text("Google may ask you to verify your account before moving this item.")
      }
      Button("Use Passkey in Browser", systemImage: "arrow.up.right.square") {
        onOpenBrowser()
        openURL(mode == .signIn ? GooglePhotosWebSession.libraryURL : GooglePhotosWebSession.lockedFolderURL)
      }
      .buttonStyle(.borderless)
      Text("Finish the move in your browser. Browser sign-in stays in the browser.")
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private func move(_ key: String, on page: WebPage) async throws -> Bool {
    isMovingOut = true
    defer { isMovingOut = false }
    guard try await library.moveOutOfLockedFolder(mediaKey: key, on: page) else { return false }
    if let lockedSession, !lockedSession.isClosed, !library.isRetired {
      lockedSession.reauthenticatedPage = page
    }
    didMove = true
    showsPage = false
    isUpdatingLibrary = true
    onMoveOutConfirmed()
    // The server already accepted the move, so sync even if the sheet is dismissed.
    let updates = Task { await library.reconcileLockedFolder(mediaKey: key) }
    let isInLibrary = await updates.value
    isUpdatingLibrary = false
    if isInLibrary, !Task.isCancelled { dismiss() }
    return true
  }

  private func open() async {
    guard !library.isRetired else { return }
    error = nil
    showsManualInstructions = false
    showsPage = false
    page = nil
    if !isSigningIn, let key = moveOutMediaKey, let authorized = lockedSession?.reauthenticatedPage {
      do {
        if try await move(key, on: authorized) { return }
      } catch is CancellationError {
        return
      } catch {
        // The saved authorization expired or Google refused the move.
      }
      lockedSession?.reauthenticatedPage = nil
      authorized.stopLoading()
    }
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
      var handedOff = false
      defer { if !handedOff { webPage.stopLoading() } }
      var pendingMove = moveOutMediaKey
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
                  handedOff = true
                  onSignIn(webPage)
                  dismiss()
                } else {
                  needsSignIn = false
                  attempt += 1
                }
                return
              }
              try await session.verifyAccount(on: webPage, waitingUpTo: .seconds(8))
              if let key = pendingMove {
                do {
                  if try await move(key, on: webPage) { return }
                } catch is CancellationError {
                  return
                } catch {
                  // Google Photos remains available for moving the item directly.
                  pendingMove = nil
                  showsManualInstructions = true
                  try await session.verifyAccount(on: webPage)
                }
              }
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
