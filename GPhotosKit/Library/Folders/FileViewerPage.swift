import AVFoundation
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A file in a backed-up folder in the viewer: the photo at screen size (sharper as you
/// zoom), or the video, played from the file.
struct FileViewerPage: View {
  let item: FolderItemInfo
  let containerSize: CGSize
  let displayScale: CGFloat
  let isCurrent: Bool
  let onTap: () -> Void
  let onDismiss: () -> Void
  let onSwipeUp: () -> Void
  /// The viewer's video controls, given this page's player while it's showing.
  let playback: VideoPlayback
  @State private var image: CGImage?
  @State private var pixelSize: CGSize = .zero
  @State private var loadedLongSide: CGFloat = 0
  @State private var token: ImageRequestToken?
  @State private var detailToken: ImageRequestToken?
  @State private var player: AVPlayer?

  /// Above this, zooming shows the most detail a layer can hold without tiling.
  private static let maxPixels: CGFloat = 24_000_000

  var body: some View {
    ZStack {
      ZoomableImage(
        image: image, pixelSize: pixelSize, liveText: isCurrent && !item.isVideo, onZoom: loadDetail, onTap: onTap,
        onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player)
      if image == nil || (item.isVideo && isCurrent && player == nil) { ProgressView() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(item.fileName))
    .task { await load() }
    .onDisappear(perform: unload)
    .task(id: isCurrent) {
      if isCurrent { startVideo() } else { player?.pause() }
    }
  }

  private var screenPixels: CGSize {
    CGSize(width: containerSize.width * displayScale, height: containerSize.height * displayScale)
  }

  private func load() async {
    if let cached = ThumbnailPipeline.shared.placeholder(for: ThumbnailKey(id: item.id, bucket: .huge)) { image = cached }
    let url = item.url
    let isVideo = item.isVideo
    pixelSize = await Task.detached(priority: .userInitiated) { await Self.pixelSize(of: url, isVideo: isVideo) }.value
    request(longSide: max(screenPixels.width, screenPixels.height), isDetail: false)
  }

  private func request(longSide: CGFloat, isDetail: Bool) {
    let request = FolderLibrary.shared.thumbnails.requestImage(
      id: item.id, pixelSize: CGSize(width: longSide, height: longSide), quality: .display
    ) { cgImage, _ in
      Task { @MainActor in
        let side = CGFloat(max(cgImage.width, cgImage.height))
        guard side >= loadedLongSide else { return }
        image = cgImage
        loadedLongSide = side
      }
    }
    if isDetail {
      detailToken?.cancel()
      detailToken = request
    } else {
      token = request
    }
  }

  /// Asks for enough pixels for the current zoom, capped at the original size.
  private func loadDetail(_ zoom: CGFloat) {
    guard zoom > 1.2, !item.isVideo, pixelSize.width > 0 else { return }
    let fitted = AspectFit.size(for: pixelSize, in: containerSize)
    var wanted = max(fitted.width, fitted.height) * zoom * displayScale
    let full = max(pixelSize.width, pixelSize.height)
    wanted = min(wanted, full)
    let aspect = min(pixelSize.width, pixelSize.height) / full
    if wanted * wanted * aspect > Self.maxPixels { wanted = (Self.maxPixels / aspect).squareRoot() }
    guard wanted > loadedLongSide * 1.25 else { return }
    request(longSide: wanted, isDetail: true)
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

  private func startVideo() {
    guard item.isVideo else { return }
    if let player {
      playback.attach(player)
      player.play()
      return
    }
    let player = AVPlayer(url: item.url)
    self.player = player
    playback.attach(player)
    player.play()
    playback.didAutoplay(player)
  }

  /// The photo's or video's size in pixels, upright.
  nonisolated static func pixelSize(of url: URL, isVideo: Bool) async -> CGSize {
    if isVideo {
      guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
        let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
      else { return .zero }
      return AspectFit.uprightSize(natural, videoTransform: transform)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else { return .zero }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return AspectFit.uprightSize(CGSize(width: width, height: height), exifOrientation: orientation)
  }
}

/// A folder file for the share sheet and drags: the file itself.
public struct FileSharedItem: Transferable, Sendable {
  let item: FolderItemInfo

  public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .movie) { shared in SentTransferredFile(shared.item.url) }
      .exportingCondition { $0.item.isVideo }
    FileRepresentation(exportedContentType: .image) { shared in SentTransferredFile(shared.item.url) }
      .exportingCondition { !$0.item.isVideo }
  }
}

/// The info panel for a folder file: where it is, when, how big, and its backup.
struct FileInfoView: View {
  let item: FolderItemInfo
  let backup: PhotoGridBadges.Backup?
  let takenAt: Date

  var body: some View {
    Form {
      Section {
        LabeledContent("Name", value: item.fileName)
        LabeledContent("Folder", value: item.folderName)
        LabeledContent("Date", value: takenAt.formatted(date: .long, time: .shortened))
        LabeledContent("Size", value: item.size.formatted(.byteCount(style: .file)))
      }
      Section {
        LabeledContent("Google Photos", value: backup?.title ?? String(localized: "Not backed up"))
      }
    }
    .formStyle(.grouped)
  }
}
