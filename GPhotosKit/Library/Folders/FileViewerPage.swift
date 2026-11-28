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
  @State private var isLoadingImage = false
  @State private var didFail = false
  @State private var pixelSize: CGSize = .zero
  @State private var token: ThumbnailTicket?
  @State private var detailToken: ThumbnailTicket?
  @State private var player: AVPlayer?

  /// Above this, zooming shows the most detail a layer can hold without tiling.
  private static let maxPixels: CGFloat = 24_000_000

  var body: some View {
    ZoomableImage(
      image: image, pixelSize: pixelSize, previewIdentity: item.thumbnailIdentity, isCurrent: isCurrent,
      isLoading: isLoadingImage, didFail: didFail,
      isBuffering: item.isVideo && (player == nil || (playback.player === player && playback.isBuffering)),
      liveText: isCurrent && !item.isVideo,
      onZoom: loadDetail, onTap: onTap, onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player,
      quarterTurns: isCurrent ? playback.quarterTurns : 0
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(item.fileName))
    .task(id: isCurrent ? screenPixels : .zero) {
      token?.cancel()
      token = nil
      if isCurrent, !Task.isCancelled { await load() }
    }
    .onDisappear(perform: unload)
    .task(id: isCurrent) {
      if isCurrent { startVideo() } else { player?.pause() }
    }
  }

  private var screenPixels: CGSize {
    CGSize(width: containerSize.width * displayScale, height: containerSize.height * displayScale)
  }

  private var cachedPreview: CGImage? { ThumbnailPipeline.shared.viewerPreview(for: item.thumbnailIdentity) }

  private func load() async {
    let intrinsic = max(pixelSize.width, pixelSize.height)
    let screenSide = max(screenPixels.width, screenPixels.height)
    let side = intrinsic > 0 ? min(intrinsic, screenSide) : screenSide
    if side > 0, !ViewerImage.hasFittedPreview(for: item.thumbnailIdentity, target: CGSize(width: side, height: 0), isFile: true) {
      request(longSide: side, isDetail: false, joining: CGSize(width: screenSide, height: screenSide))
    }
    guard pixelSize == .zero else { return }
    let url = item.url
    let isVideo = item.isVideo
    let size = await Self.pixelSize(of: url, isVideo: isVideo)
    guard !Task.isCancelled else { return }
    pixelSize = size
  }

  private func request(longSide: CGFloat, isDetail: Bool, joining: CGSize? = nil) {
    if !isDetail {
      isLoadingImage = !item.isVideo
      didFail = false
    }
    let request = ViewerImage.request(
      FolderLibrary.shared.thumbnails, identity: item.thumbnailIdentity, pixels: CGSize(width: longSide, height: longSide),
      isFile: true, joining: joining, onEnd: { if !isDetail { ended() } },
      deliver: { candidate, isFinal in
        if ViewerImage.accepts(candidate, over: image ?? cachedPreview, isFinal: isFinal) { image = candidate }
      })
    if isDetail {
      detailToken?.cancel()
      detailToken = request
    } else {
      token = request
    }
  }

  private func ended() {
    isLoadingImage = false
    didFail = !item.isVideo && image == nil && cachedPreview == nil
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
    guard wanted > CGFloat(ViewerImage.longSide(image ?? cachedPreview)) * 1.25 else { return }
    request(longSide: wanted, isDetail: true)
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
  @concurrent static func pixelSize(of url: URL, isVideo: Bool) async -> CGSize {
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
