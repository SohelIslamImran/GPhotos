import SwiftUI
import WebKit

@MainActor
@Observable
final class LockedFolderMove {
  struct Target {
    let library: CloudLibrary
    let items: [RemoteItemSummary]
    let keepsLocalCopies: Bool
    let didMove: () -> Void

    var title: String {
      items.count == 1
        ? String(localized: "Move 1 Item to Locked Folder?")
        : String(localized: "Move \(items.count) Items to Locked Folder?")
    }

    var message: String {
      let hidden =
        items.count == 1
        ? String(localized: "Google Photos hides it from your library, albums, search, and memories.")
        : String(localized: "Google Photos hides them from your library, albums, search, and memories.")
      guard keepsLocalCopies else { return hidden }
      return hidden + " " + String(localized: "Copies on this device stay on this device.")
    }
  }

  static let title = String(localized: "Move to Locked Folder")
  static let symbol = "lock.fill"

  var pending: Target?
  private(set) var signingIn: Target?
  var showsSignIn = false
  var error: String?
  private(set) var isMoving = false

  /// `keepsLocalCopies`: the items were picked through device or folder copies, which only Google Photos locks.
  func request(
    _ items: [RemoteItemSummary], in library: CloudLibrary, keepsLocalCopies: Bool = false,
    didMove: @escaping () -> Void = {}
  ) {
    guard !isMoving, signingIn == nil, !library.isRetired else { return }
    let eligible = CloudLibrary.lockableItems(items, excluding: LockedItems.keys(accountEmail: library.accountEmail))
    guard !eligible.isEmpty else { return }
    pending = Target(library: library, items: eligible, keepsLocalCopies: keepsLocalCopies, didMove: didMove)
  }

  func move(_ target: Target, signedInPage: WebPage? = nil) {
    pending = nil
    guard !isMoving else { return }
    isMoving = true
    Task {
      defer { isMoving = false }
      do {
        try await target.library.moveToLockedFolder(target.items, signedInPage: signedInPage)
        target.didMove()
      } catch is CancellationError {
      } catch GooglePhotosWebError.signInRequired where signedInPage == nil {
        signingIn = target
        showsSignIn = true
      } catch GooglePhotosWebError.wrongAccount where signedInPage == nil {
        signingIn = target
        showsSignIn = true
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  func signInDismissed(page: WebPage?) {
    let target = signingIn
    signingIn = nil
    if let page, let target { move(target, signedInPage: page) }
  }
}

struct LockedFolderMovePresentation: ViewModifier {
  @Bindable var move: LockedFolderMove
  @State private var signedInPage: WebPage?

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        move.pending?.title ?? LockedFolderMove.title,
        isPresented: Binding(get: { move.pending != nil }, set: { if !$0 { move.pending = nil } }),
        titleVisibility: .visible, presenting: move.pending
      ) { target in
        Button(LockedFolderMove.title) { move.move(target) }
      } message: { target in
        Text(target.message)
      }
      .overlay {
        if move.isMoving {
          ProgressView("Moving to Locked Folder…")
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
      }
      .sheet(
        isPresented: $move.showsSignIn,
        onDismiss: {
          move.signInDismissed(page: signedInPage)
          signedInPage = nil
        }
      ) {
        if let target = move.signingIn {
          GooglePhotosWebSheet(library: target.library, mode: .signIn) { signedInPage = $0 }
        }
      }
      .alert("Couldn’t Finish Moving", isPresented: Binding(get: { move.error != nil }, set: { if !$0 { move.error = nil } })) {
        Button("OK") {}
      } message: {
        Text(move.error ?? "")
      }
  }
}
