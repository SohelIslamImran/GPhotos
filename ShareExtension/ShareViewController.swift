import GPhotosKit
import SwiftUI
import UIKit

/// iOS share-extension shell. The staging logic and UI live in `GPhotosKit` so this
/// stays identical to the macOS extension.
final class ShareViewController: UIViewController {
  private let model = ShareStagingModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let rootView = ShareStagingView(
      model: model,
      complete: { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      },
      cancel: { [weak self] in
        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      }
    )

    let host = UIHostingController(rootView: rootView)
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)

    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)

    Task {
      await model.loadAttachments(from: extensionContext)
    }
  }
}
