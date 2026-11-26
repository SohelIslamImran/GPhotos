import Photos
import PhotosUI
import SwiftUI
import os

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
        let photo: PHLivePhoto? = await ViewerPhotoKitRequest.run { manager, finish in
          manager.requestLivePhoto(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { photo, info in
            if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
              finish(nil)
            } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
              finish(photo)
            }
          }
        }
        guard !Task.isCancelled else { return }
        livePhoto = photo
        if livePhoto == nil { onEnd() }
      }
  }
}

/// PhotoKit may call back before returning a request ID, or after cancellation.
@MainActor
enum ViewerPhotoKitRequest {
  static func run<Value: Sendable>(
    _ start: (PHImageManager, @escaping @Sendable (Value?) -> Void) -> PHImageRequestID
  ) async -> Value? {
    let manager = PHImageManager.default()
    let request = OSAllocatedUnfairLock(initialState: Request<Value>())
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let shouldStart = request.withLock { state in
          guard !state.cancelled else { return false }
          state.continuation = continuation
          return true
        }
        guard shouldStart else {
          continuation.resume(returning: nil)
          return
        }
        let id = start(manager) { value in
          let completion = request.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
          }
          completion?.resume(returning: value)
        }
        let shouldCancel = request.withLock { state in
          state.id = id
          return state.cancelled
        }
        if shouldCancel { manager.cancelImageRequest(id) }
      }
    } onCancel: {
      let (id, continuation) = request.withLock { state in
        state.cancelled = true
        defer { state.continuation = nil }
        return (state.id, state.continuation)
      }
      if let id { manager.cancelImageRequest(id) }
      continuation?.resume(returning: nil)
    }
  }

  private struct Request<Value: Sendable>: Sendable {
    var id: PHImageRequestID?
    var cancelled = false
    var continuation: CheckedContinuation<Value?, Never>?
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
