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
  @State private var token: ImageRequestToken?
  @State private var detailToken: ImageRequestToken?
  @State private var loadedLongSide: CGFloat = 0
  @State private var player: AVPlayer?

  /// Above this, zooming shows the most detail a layer can hold without tiling.
  private static let maxPixels: CGFloat = 24_000_000

  var body: some View {
    let pixelSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    ZStack {
      if asset.mediaType == .video {
        ZoomableImage(
          image: image, pixelSize: pixelSize, onTap: onTap, onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player)
        if isCurrent, player == nil { ProgressView() }
      } else {
        ZoomableImage(
          image: image, pixelSize: pixelSize, liveText: isCurrent && !playsLive, onZoom: loadDetail, onTap: onTap,
          onDismiss: onDismiss, onSwipeUp: onSwipeUp)
        if playsLive {
          LivePhotoPlayer(asset: asset, pixelSize: screenPixels, onEnd: onLiveEnd)
            .allowsHitTesting(false)
        }
      }
      if image == nil, asset.mediaType != .video { ProgressView() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(label))
    .onAppear(perform: load)
    .onDisappear(perform: unload)
    .task(id: isCurrent) {
      if isCurrent { await startVideo() } else { player?.pause() }
    }
  }

  private var screenPixels: CGSize {
    CGSize(width: containerSize.width * displayScale, height: containerSize.height * displayScale)
  }

  private func load() {
    let id = asset.localIdentifier
    PhotoKitImageSource.shared.remember(asset)
    token = PhotoKitImageSource.shared.requestImage(id: id, pixelSize: screenPixels, quality: .display) { cgImage, _ in
      Task { @MainActor in
        // A sharper zoomed image may already be showing.
        guard CGFloat(max(cgImage.width, cgImage.height)) >= loadedLongSide else { return }
        image = cgImage
        loadedLongSide = CGFloat(max(cgImage.width, cgImage.height))
      }
    }
  }

  /// Asks for enough pixels for the current zoom, capped at the original size.
  private func loadDetail(_ zoom: CGFloat) {
    guard zoom > 1.2 else { return }
    let decoded = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    let full = AspectFit.orientedSize(decoded: decoded, metadata: CGSize(width: asset.pixelWidth, height: asset.pixelHeight))
    let fitted = AspectFit.size(for: full, in: containerSize)
    var wanted = CGSize(width: fitted.width * zoom * displayScale, height: fitted.height * zoom * displayScale)
    if wanted.width > full.width { wanted = full }
    let pixels = wanted.width * wanted.height
    if pixels > Self.maxPixels {
      let scale = (Self.maxPixels / pixels).squareRoot()
      wanted = CGSize(width: wanted.width * scale, height: wanted.height * scale)
    }
    guard max(wanted.width, wanted.height) > loadedLongSide * 1.25 else { return }
    detailToken?.cancel()
    detailToken = PhotoKitImageSource.shared.requestImage(
      id: asset.localIdentifier, pixelSize: wanted, quality: .display
    ) { cgImage, _ in
      Task { @MainActor in
        guard CGFloat(max(cgImage.width, cgImage.height)) > loadedLongSide else { return }
        image = cgImage
        loadedLongSide = CGFloat(max(cgImage.width, cgImage.height))
      }
    }
  }

  private func unload() {
    token?.cancel()
    detailToken?.cancel()
    token = nil
    detailToken = nil
    image = nil
    loadedLongSide = 0
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
    let item: AVPlayerItem? = await withCheckedContinuation { continuation in
      PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
        continuation.resume(returning: item)
      }
    }
    guard let item, isCurrent, !Task.isCancelled else { return }
    let player = AVPlayer(playerItem: item)
    self.player = player
    playback.attach(player)
    player.play()
    playback.didAutoplay(player)
  }
}
