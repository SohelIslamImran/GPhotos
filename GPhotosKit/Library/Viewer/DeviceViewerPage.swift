import AVFoundation
import Photos
import SwiftUI

/// A photo-library asset in the viewer.
struct DeviceViewerPage: View {
  let asset: PHAsset
  let label: String
  let containerSize: CGSize
  let displayScale: CGFloat
  let isCurrent: Bool
  let playsLive: Bool
  let onTap: () -> Void
  let onDismiss: () -> Void
  let onSwipeUp: () -> Void
  let onLiveEnd: () -> Void
  /// The viewer's video controls, given this page's player while it's showing.
  let playback: VideoPlayback
  @State private var image: CGImage?
  @State private var isLoadingImage = false
  @State private var didFail = false
  @State private var token: ThumbnailTicket?
  @State private var detailToken: ThumbnailTicket?
  @State private var player: AVPlayer?

  /// Above this, zooming shows the most detail a layer can hold without tiling.
  private static let maxPixels: CGFloat = 24_000_000

  var body: some View {
    let pixelSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    ZStack {
      if asset.mediaType == .video {
        ZoomableImage(
          image: image, pixelSize: pixelSize, previewIdentity: identity, isCurrent: isCurrent,
          isBuffering: player == nil || (playback.player === player && playback.isBuffering), onTap: onTap, onDismiss: onDismiss,
          onSwipeUp: onSwipeUp, player: player)
      } else {
        ZoomableImage(
          image: image, pixelSize: pixelSize, previewIdentity: identity, isCurrent: isCurrent, isLoading: isLoadingImage, didFail: didFail,
          liveText: isCurrent && !playsLive,
          onZoom: loadDetail, onTap: onTap,
          onDismiss: onDismiss, onSwipeUp: onSwipeUp)
        if playsLive {
          LivePhotoPlayer(asset: asset, pixelSize: screenPixels, onEnd: onLiveEnd)
            .allowsHitTesting(false)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(label))
    .task(id: isCurrent ? screenPixels : .zero) {
      token?.cancel()
      token = nil
      if isCurrent, !Task.isCancelled { load() }
    }
    .onDisappear(perform: unload)
    .task(id: isCurrent) {
      if isCurrent { await startVideo() } else { player?.pause() }
    }
  }

  private var screenPixels: CGSize {
    ViewerImage.fittedPixels(
      CGSize(width: asset.pixelWidth, height: asset.pixelHeight), in: containerSize, scale: displayScale)
  }

  private var identity: ThumbnailIdentity { PhotoKitImageSource.identity(for: asset) }
  private var cachedPreview: CGImage? { ThumbnailPipeline.shared.viewerPreview(for: identity) }

  private func load() {
    isLoadingImage = false
    guard screenPixels != .zero, !ViewerImage.hasFittedPreview(for: identity, target: screenPixels) else { return }
    isLoadingImage = true
    didFail = false
    PhotoKitImageSource.shared.remember(asset)
    token = ViewerImage.requestCurrentAsset(
      PhotoKitImageSource.shared, identity: identity, pixels: screenPixels, onEnd: ended, deliver: receive)
  }

  private func ended() {
    isLoadingImage = false
    didFail = image == nil && cachedPreview == nil
  }

  private func receive(_ candidate: CGImage, isFinal: Bool) {
    if ViewerImage.accepts(candidate, over: image ?? cachedPreview, isFinal: isFinal) { image = candidate }
  }

  /// Asks for enough pixels for the current zoom, capped at the original size.
  private func loadDetail(_ zoom: CGFloat) {
    guard zoom > 1.2 else { return }
    let decoded = (image ?? cachedPreview).map(ViewerImage.size) ?? .zero
    let full = AspectFit.orientedSize(decoded: decoded, metadata: CGSize(width: asset.pixelWidth, height: asset.pixelHeight))
    let fitted = AspectFit.size(for: full, in: containerSize)
    var wanted = CGSize(width: fitted.width * zoom * displayScale, height: fitted.height * zoom * displayScale)
    if wanted.width > full.width { wanted = full }
    let pixels = wanted.width * wanted.height
    if pixels > Self.maxPixels {
      let scale = (Self.maxPixels / pixels).squareRoot()
      wanted = CGSize(width: wanted.width * scale, height: wanted.height * scale)
    }
    guard max(wanted.width, wanted.height) > CGFloat(ViewerImage.longSide(image ?? cachedPreview)) * 1.25 else { return }
    detailToken?.cancel()
    detailToken = ViewerImage.request(
      PhotoKitImageSource.shared, identity: identity, pixels: wanted, deliver: receive)
  }

  private func unload() {
    isLoadingImage = false
    token?.cancel()
    detailToken?.cancel()
    token = nil
    detailToken = nil
    image = nil
    player?.pause()
    player = nil
  }

  private func startVideo() async {
    guard asset.mediaType == .video else { return }
    if let player {
      playback.attach(player)
      player.play()
      return
    }
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .automatic
    let item: AVPlayerItem? = await ViewerPhotoKitRequest.run { manager, finish in
      manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in finish(item) }
    }
    guard let item, isCurrent, !Task.isCancelled else { return }
    let player = AVPlayer(playerItem: item)
    self.player = player
    playback.attach(player)
    player.play()
    playback.didAutoplay(player)
  }
}
