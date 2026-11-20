import AppKit
import GPhotosKit
import SwiftUI

/// macOS share-extension shell. Presents the same staging UI as the iOS extension; the
/// logic and views live in `GPhotosKit` so the two cannot drift apart.
final class ShareViewController: NSViewController {
  private let model = ShareStagingModel()

  /// Retained so the hosting controller — which owns the SwiftUI environment and
  /// toolbar bridge — outlives `loadView`.
  private var hostingController: NSHostingController<ShareStagingView>?

  override func loadView() {
    let rootView = ShareStagingView(
      model: model,
      complete: { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      },
      cancel: { [weak self] in
        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      }
    )
    let hosting = NSHostingController(rootView: rootView)
    // The share sheet takes its size from `preferredContentSize`, so report the
    // SwiftUI content's own size instead of letting it open as a large window.
    hosting.sizingOptions = [.preferredContentSize]
    hostingController = hosting
    addChild(hosting)
    view = NSView()
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    preferredContentSize = hosting.preferredContentSize
  }

  override func preferredContentSizeDidChange(for viewController: NSViewController) {
    super.preferredContentSizeDidChange(for: viewController)
    preferredContentSize = viewController.preferredContentSize
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    // SwiftUI's `navigationTitle` needs the hosting controller to own the window,
    // which it does not here, so the sheet would otherwise be titled "Untitled".
    view.window?.title = ProductCopy.name
    Task {
      await model.loadAttachments(from: extensionContext)
    }
  }
}
