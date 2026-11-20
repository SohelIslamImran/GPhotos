import Photos
import PhotosUI
import SwiftUI

/// Plays a Live Photo once with sound, then reports that it finished.
struct LivePhotoPlayer: View {
  let asset: PHAsset
  let pixelSize: CGSize
  let onEnd: () -> Void
  @State private var livePhoto: PHLivePhoto?

  var body: some View {
    LivePhotoRepresentable(livePhoto: livePhoto, onEnd: onEnd)
      .task(id: asset.localIdentifier) {
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let asset = asset
        let size = pixelSize
        livePhoto = await withCheckedContinuation { continuation in
          var resumed = false
          PHImageManager.default().requestLivePhoto(
            for: asset, targetSize: size, contentMode: .aspectFit, options: options
          ) { photo, info in
            // High quality delivers once; guard anyway against a degraded first call.
            guard !resumed, (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            resumed = true
            continuation.resume(returning: photo)
          }
        }
        if livePhoto == nil { onEnd() }
      }
  }
}

@MainActor
private final class LivePhotoDelegate: NSObject, PHLivePhotoViewDelegate {
  var onEnd: () -> Void = {}

  nonisolated func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
    MainActor.assumeIsolated { onEnd() }
  }
}

#if os(iOS)
  private struct LivePhotoRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto?
    let onEnd: () -> Void

    func makeCoordinator() -> LivePhotoDelegate { LivePhotoDelegate() }

    func makeUIView(context: Context) -> PHLivePhotoView {
      let view = PHLivePhotoView()
      view.contentMode = .scaleAspectFit
      view.delegate = context.coordinator
      return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
      context.coordinator.onEnd = onEnd
      guard let livePhoto, view.livePhoto !== livePhoto else { return }
      view.livePhoto = livePhoto
      view.startPlayback(with: .full)
    }
  }
#else
  private struct LivePhotoRepresentable: NSViewRepresentable {
    let livePhoto: PHLivePhoto?
    let onEnd: () -> Void

    func makeCoordinator() -> LivePhotoDelegate { LivePhotoDelegate() }

    func makeNSView(context: Context) -> PHLivePhotoView {
      let view = PHLivePhotoView()
      view.contentMode = .aspectFit
      view.livePhotoBadgeView?.isHidden = true
      view.delegate = context.coordinator
      return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
      context.coordinator.onEnd = onEnd
      guard let livePhoto, view.livePhoto !== livePhoto else { return }
      view.livePhoto = livePhoto
      view.startPlayback(with: .full)
    }
  }
#endif
