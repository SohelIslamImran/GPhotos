import CoreTransferable
import SwiftUI

#if os(iOS)
  import LinkPresentation
  import UIKit
#else
  import AppKit
#endif

/// "1 Photo", "3 Videos", "5 Items": the share sheet's header.
func shareTitle(count: Int, videoCount: Int) -> String {
  if videoCount == 0 { return count == 1 ? String(localized: "1 Photo") : String(localized: "\(count) Photos") }
  if videoCount == count { return count == 1 ? String(localized: "1 Video") : String(localized: "\(count) Videos") }
  return String(localized: "\(count) Items")
}

/// Shares photos and videos: on iPhone through `SharePresenter` (the photo in the sheet's
/// header), on the Mac through the standard share menu.
///
/// What's shared is worked out when it's needed: on iPhone at the tap, so a toolbar that
/// redraws with a whole library selected doesn't build a list of it every time.
struct PhotoShareButton<Item: Transferable & Sendable, Label: View>: View {
  private let items: () -> [Item]
  /// The pixel identities used by the grid and viewer.
  private let identities: () -> [ThumbnailIdentity]
  private let videoCount: () -> Int
  private let label: () -> Label

  init(
    items: @escaping @autoclosure () -> [Item], identities: @escaping @autoclosure () -> [ThumbnailIdentity],
    videoCount: @escaping @autoclosure () -> Int, @ViewBuilder label: @escaping () -> Label
  ) {
    self.items = items
    self.identities = identities
    self.videoCount = videoCount
    self.label = label
  }

  var body: some View {
    #if os(iOS)
      Button {
        SharePresenter.share(items(), identities: identities(), videoCount: videoCount())
      } label: {
        label()
      }
    #else
      let items = items()
      let title = shareTitle(count: items.count, videoCount: videoCount())
      ShareLink(items: items) { _ in
        SharePreview(title)
      } label: {
        label()
      }
    #endif
  }
}

extension RemoteItemSummary {
  /// The id grids and the thumbnail cache know this item by.
  var thumbnailID: String { RemoteThumbnailID(mediaKey: mediaKey, contentVersion: contentVersion).string }
}

#if os(iOS)
  /// The system share sheet for photos and videos, with the photo in its header (a
  /// `ShareLink` without a preview image shows a blank document icon). Files are exported
  /// only once an activity asks for them.
  @MainActor
  public enum SharePresenter {
    public static func share<Item: Transferable & Sendable>(
      _ items: [Item], identities: [ThumbnailIdentity], videoCount: Int, thumbnail: CGImage? = nil
    ) {
      guard !items.isEmpty else { return }
      let providers = items.map { item in
        let provider = NSItemProvider()
        provider.register(item)
        return provider
      }
      let image = (thumbnail ?? identities.first.flatMap(cachedThumbnail)).map { UIImage(cgImage: $0) }
      let title = shareTitle(count: items.count, videoCount: videoCount)
      let configuration = UIActivityItemsConfiguration(itemProviders: providers)
      configuration.metadataProvider = { key in
        switch key {
        case .title: return title
        case .linkPresentationMetadata:
          let metadata = LPLinkMetadata()
          metadata.title = title
          if let image {
            metadata.imageProvider = NSItemProvider(object: image)
            metadata.iconProvider = NSItemProvider(object: image)
          }
          return metadata
        default: return nil
        }
      }
      configuration.previewProvider = { index, _, _ in
        guard identities.indices.contains(index), let preview = cachedThumbnail(identities[index]) else { return nil }
        return NSItemProvider(object: UIImage(cgImage: preview))
      }
      let controller = UIActivityViewController(activityItemsConfiguration: configuration)
      guard let presenter = topViewController() else { return }
      controller.popoverPresentationController?.sourceView = presenter.view
      controller.popoverPresentationController?.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1)
      presenter.present(controller, animated: true)
    }

    /// The largest thumbnail already in memory: the grid or viewer just showed it.
    static func cachedThumbnail(_ identity: ThumbnailIdentity) -> CGImage? {
      ThumbnailPipeline.shared.viewerPreview(for: identity)
        ?? ThumbnailPipeline.shared.placeholder(for: ThumbnailKey(identity: identity, bucket: .huge))
    }

    static func topViewController() -> UIViewController? {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      var controller = scene?.keyWindow?.rootViewController
      while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
        controller = presented
      }
      return controller
    }
  }
#endif

#if os(macOS)
  @MainActor
  enum SharePresenter {
    static func share<Item: Transferable & Sendable>(_ items: [Item], identities: [ThumbnailIdentity], videoCount: Int) {
      guard !items.isEmpty, let window = NSApp.keyWindow, let view = window.contentView else { return }
      let providers = items.map { item in
        let provider = NSItemProvider()
        provider.register(item)
        return provider
      }
      let picker = NSSharingServicePicker(items: providers)
      let menu = NSMenu()
      menu.addItem(picker.standardShareMenuItem)
      menu.popUp(positioning: nil, at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
    }
  }
#endif
