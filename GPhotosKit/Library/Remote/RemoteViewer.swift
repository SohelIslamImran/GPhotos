import AVFoundation
import MapKit
import Photos
import SwiftUI

/// A Google Photos item in the viewer.
struct RemoteViewerPage: View {
  let library: CloudLibrary
  let item: RemoteItemSummary
  let containerSize: CGSize
  let displayScale: CGFloat
  let isCurrent: Bool
  let onTap: () -> Void
  let onDismiss: () -> Void
  let onSwipeUp: () -> Void
  /// The viewer's video controls, given this page's player while it's showing.
  let playback: VideoPlayback
  @State private var localFile: FolderItemInfo?
  @State private var localAsset: PHAsset?
  @State private var resolvedLocalCopy = false
  @State private var image: CGImage?
  @State private var isLoadingImage = false
  @State private var didFail = false
  @State private var token: ThumbnailTicket?
  @State private var detailToken: ThumbnailTicket?
  @State private var player: AVPlayer?
  @State private var playerObservation: NSKeyValueObservation?
  @State private var videoFailed = false
  @State private var usesOriginal = false
  @State private var attempt = 0

  private var imageID: String { RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion).string }
  private var identity: ThumbnailIdentity { library.localFirstThumbnails.thumbnailIdentity(for: imageID) }
  private var blocked: Bool { identity.isLocked || library.isRetired }
  private var cachedPreview: CGImage? { ThumbnailPipeline.shared.viewerPreview(for: identity) }
  private var pixelSize: CGSize { CGSize(width: item.width ?? 0, height: item.height ?? 0) }

  private var imageRoute: LocalFirstThumbnailSource.Route {
    _ = library.localCopyRevision
    return library.localFirstThumbnails.route(for: item.mediaKey)
  }

  private struct Request: Hashable {
    let route: LocalFirstThumbnailSource.Route
    let blocked: Bool
    let attempt: Int
    let assetVersion: PhotoBackupEvidence.Version?
    let file: FolderItemInfo?
  }

  var body: some View {
    ZStack {
      if blocked {
        Color.clear
      } else if let localAsset {
        DeviceViewerPage(
          asset: localAsset, label: item.fileName, containerSize: containerSize, displayScale: displayScale,
          isCurrent: isCurrent, playsLive: false, onTap: onTap, onDismiss: onDismiss,
          onSwipeUp: onSwipeUp, onLiveEnd: {}, playback: playback)
      } else if let localFile {
        FileViewerPage(
          item: localFile, containerSize: containerSize, displayScale: displayScale,
          isCurrent: isCurrent, onTap: onTap, onDismiss: onDismiss, onSwipeUp: onSwipeUp, playback: playback)
      } else {
        ZoomableImage(
          image: image, pixelSize: pixelSize, previewIdentity: identity, isCurrent: isCurrent, showsProgress: !videoFailed,
          isLoading: isLoadingImage || (!resolvedLocalCopy && item.kind != .video), didFail: didFail,
          isBuffering: item.kind == .video && (player == nil || (playback.player === player && playback.isBuffering)),
          liveText: isCurrent && item.kind != .video, onZoom: loadDetail, onTap: onTap,
          onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player,
          quarterTurns: isCurrent ? playback.quarterTurns : 0
        )
      }
      if videoFailed, isCurrent, !blocked {
        VStack(spacing: 12) {
          Text("Couldn't Play Video").font(.headline)
          Button("Try Again", systemImage: "arrow.clockwise") {
            videoFailed = false
            usesOriginal = false
            attempt &+= 1
          }
          .buttonStyle(.glass)
        }
        .padding(20)
        .glassEffect(in: .rect(cornerRadius: 20))
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: LockedItems.didLock).receive(on: DispatchQueue.main)) { _ in
      if blocked { clearMedia() }
    }
    .onChange(of: library.isRetired) {
      if library.isRetired { clearMedia() }
    }
    .onDisappear(perform: clearMedia)
    .task(id: request) {
      guard !blocked else { return }
      let source = library.localFirstThumbnails
      let checked = source.localCopies
      let key = item.mediaKey
      let route = checked.route(for: key)
      if route != .remote || localAsset != nil || localFile != nil { resolvedLocalCopy = false }
      if !resolvedLocalCopy {
        switch route {
        case .asset(let id):
          let asset = await Task.detached(priority: .userInitiated) {
            guard let asset = LocalFirstThumbnailSource.visibleAsset(id),
              LocalFirstThumbnailSource.hasCurrentVersion(asset, checked.assetVersions[id])
            else { return nil as PHAsset? }
            return asset
          }.value
          guard !Task.isCancelled, !blocked else { return }
          guard let asset else {
            source.discardAlias(for: key, route: route, checked: checked)
            return
          }
          localFile = nil
          localAsset = asset
        case .file:
          guard let file = checked.files[key] else { return }
          let current = await Task.detached(priority: .userInitiated) {
            LocalFirstThumbnailSource.fileAliasIsCurrent(file)
          }.value
          guard !Task.isCancelled, !blocked else { return }
          guard current else {
            source.discardAlias(for: key, route: route, checked: checked)
            return
          }
          localAsset = nil
          localFile = file
        case .remote:
          localAsset = nil
          localFile = nil
        }
        guard !Task.isCancelled, !blocked else { return }
        resolvedLocalCopy = true
      }
      if route != .remote {
        token?.cancel()
        token = nil
        detailToken?.cancel()
        detailToken = nil
        image = nil
        player?.pause()
        if playback.player === player { playback.attach(nil) }
        playerObservation = nil
        player = nil
        return
      }
      guard source.route(for: key) == .remote else { return }
      if isCurrent {
        await startVideo()
      } else {
        player?.pause()
        if playback.player === player { playback.attach(nil) }
      }
    }
    .task(id: resolvedLocalCopy && localAsset == nil && localFile == nil ? screenSide : 0) {
      token?.cancel()
      token = nil
      guard resolvedLocalCopy, imageRoute == .remote, localAsset == nil, localFile == nil, screenSide > 0,
        !Task.isCancelled,
        !ViewerImage.hasFittedPreview(for: identity, target: CGSize(width: CGFloat(screenSide), height: 0))
      else { return }
      load(side: screenSide)
    }
  }

  private func clearMedia() {
    token?.cancel()
    token = nil
    detailToken?.cancel()
    detailToken = nil
    localAsset = nil
    localFile = nil
    resolvedLocalCopy = false
    isLoadingImage = false
    image = nil
    playerObservation = nil
    if let player { playback.stop(player) }
    player = nil
  }

  private var request: Request {
    let route = imageRoute
    let copies = library.localFirstThumbnails.localCopies
    let key = item.mediaKey
    return Request(
      route: route, blocked: blocked, attempt: isCurrent ? attempt : -1,
      assetVersion: copies.assets[key].flatMap { copies.assetVersions[$0] }, file: copies.files[key])
  }

  private var screenSide: Int {
    let fitted = ViewerImage.fittedPixels(pixelSize, in: containerSize, scale: displayScale)
    return Int(max(fitted.width, fitted.height))
  }

  private func load(side: Int) {
    guard !blocked, imageRoute == .remote else { return }
    let isScreen = side <= screenSide
    if isScreen {
      isLoadingImage = item.kind != .video
      didFail = false
    }
    let request = ViewerImage.request(
      library.localFirstThumbnails, identity: identity, pixels: CGSize(width: side, height: side),
      onEnd: { if isScreen { ended() } },
      deliver: { candidate, isFinal in
        guard !blocked, imageRoute == .remote else { return }
        if ViewerImage.accepts(candidate, over: image ?? cachedPreview, isFinal: isFinal) { image = candidate }
      })
    if side > screenSide {
      detailToken?.cancel()
      detailToken = request
    } else {
      token = request
    }
  }

  private func ended() {
    isLoadingImage = false
    didFail = item.kind != .video && image == nil && cachedPreview == nil
  }

  private func loadDetail(_ zoom: CGFloat) {
    guard zoom > 1.2 else { return }
    let full = max(item.width ?? 0, item.height ?? 0)
    var wanted = Int(CGFloat(screenSide) * zoom)
    if full > 0 { wanted = min(wanted, full) }
    guard CGFloat(wanted) > CGFloat(ViewerImage.longSide(image ?? cachedPreview)) * 1.25 else { return }
    load(side: wanted)
  }

  /// Both HLS and the original are streamed; opening a video never stages a full copy.
  private func startVideo() async {
    guard !blocked, imageRoute == .remote, !Task.isCancelled else { return }
    if player?.currentItem?.status == .failed {
      playerObservation = nil
      player = nil
    }
    guard item.kind == .video, player == nil, !videoFailed else {
      if let player {
        playback.attach(player)
        player.play()
      }
      return
    }
    if !usesOriginal {
      do {
        let stream = try await library.streamingPlaylist(item)
        if try await play(url: stream.url, headers: stream.headers) { return }
      } catch {
        guard !Task.isCancelled, !blocked else { return }
      }
      usesOriginal = true
    }
    guard !blocked, imageRoute == .remote, !Task.isCancelled else { return }
    do {
      let stream = try await library.videoURL(item)
      let started = try await play(url: stream.url, headers: stream.headers)
      if !started, !Task.isCancelled, !blocked { videoFailed = true }
    } catch {
      if !Task.isCancelled, !blocked { videoFailed = true }
    }
  }

  private func play(url: URL, headers: [String: String]) async throws -> Bool {
    try library.checkUnlocked(item.mediaKey)
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    guard try await asset.load(.isPlayable) else { return false }
    try library.checkUnlocked(item.mediaKey)
    guard isCurrent else { return false }
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    self.player = player
    // isPlayable validates the format, but a segment can still fail after play starts.
    playerObservation = item.observe(\.status, options: [.new]) { item, _ in
      guard item.status == .failed else { return }
      Task { @MainActor in
        guard self.player === player, playback.player === player else { return }
        player.pause()
        playback.attach(nil)
        self.player = nil
        playerObservation = nil
        if usesOriginal {
          videoFailed = true
        } else {
          usesOriginal = true
          attempt &+= 1
        }
      }
    }
    playback.attach(player)
    player.play()
    playback.didAutoplay(player)
    return true
  }
}

/// The info panel for a Google Photos item, from the synced metadata.
struct RemoteInfoView: View {
  let library: CloudLibrary
  let summary: RemoteItemSummary
  let isOnDevice: Bool
  @State private var item: RemoteMediaItem?
  @State private var caption = ""
  @State private var errorMessage: String?

  var body: some View {
    Form {
      if let item {
        Section {
          TextField("Add a Caption", text: $caption, axis: .vertical)
            .onSubmit(saveCaption)
            .submitLabel(.done)
        }
        Section {
          LabeledContent("Date", value: item.takenAt.formatted(date: .complete, time: .omitted))
          LabeledContent("Time", value: timeDescription(item))
          LabeledContent("Name", value: item.fileName)
        }
        Section {
          if let camera = cameraDescription(item) { LabeledContent("Camera", value: camera) }
          LabeledContent("Size", value: sizeDescription(item))
          if let duration = item.duration {
            LabeledContent("Length", value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
          }
          if !exposure(item).isEmpty { Text(exposure(item).joined(separator: "  ·  ")).font(.callout.monospacedDigit()) }
        }
        Section("Google Photos") {
          Label(storageDescription(item), systemImage: item.quotaChargedBytes > 0 ? "externaldrive.badge.icloud" : "checkmark.seal")
          if let uploaded = item.uploadedAt {
            LabeledContent("Uploaded", value: uploaded.formatted(date: .abbreviated, time: .shortened))
          }
          if isOnDevice { Label("Backed up from this device", systemImage: "iphone") }
          if item.isArchived { Label("Archived", systemImage: "archivebox") }
          if let trashed = item.trashedAt { Label(RemoteLibraryGridModel.daysLeft(trashedAt: trashed), systemImage: "trash") }
        }
        if let latitude = item.latitude, let longitude = item.longitude {
          let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
          Section("Location") {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000))) {
              Marker(item.locationName ?? "", coordinate: coordinate)
            }
            .frame(height: 180)
            .clipShape(.rect(cornerRadius: 12))
            .listRowInsets(EdgeInsets())
            if let name = item.locationName { Text(name) }
          }
        }
      } else {
        ProgressView()
      }
    }
    .formStyle(.grouped)
    .task(id: summary.mediaKey) {
      item = await library.item(mediaKey: summary.mediaKey)
      caption = item?.caption ?? ""
    }
    .alert("Couldn't Save Caption", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK") {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func saveCaption() {
    let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text != (item?.caption ?? "") else { return }
    Task {
      do { try await library.setCaption(summary, caption: text) } catch { errorMessage = error.localizedDescription }
    }
  }

  private func timeDescription(_ item: RemoteMediaItem) -> String {
    var text = item.takenAt.formatted(date: .omitted, time: .shortened)
    if let offset = item.timezoneOffsetMinutes {
      let sign = offset < 0 ? "−" : "+"
      text += String(format: " GMT\(sign)%d:%02d", abs(offset) / 60, abs(offset) % 60)
    }
    return text
  }

  private func cameraDescription(_ item: RemoteMediaItem) -> String? {
    guard let model = item.cameraModel else { return nil }
    guard let make = item.cameraMake, !model.localizedCaseInsensitiveContains(make) else { return model }
    return "\(make) \(model)"
  }

  private func sizeDescription(_ item: RemoteMediaItem) -> String {
    var parts: [String] = []
    if let width = item.width, let height = item.height { parts.append("\(width) × \(height)") }
    if item.sizeBytes > 0 { parts.append(item.sizeBytes.formatted(.byteCount(style: .file))) }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }

  private func exposure(_ item: RemoteMediaItem) -> [String] {
    var parts: [String] = []
    if let iso = item.iso { parts.append("ISO \(iso)") }
    if let focal = item.focalLength { parts.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
    if let aperture = item.aperture { parts.append("ƒ\(aperture.formatted(.number.precision(.fractionLength(0...1))))") }
    if let shutter = item.shutterSpeed, shutter > 0 {
      parts.append(
        shutter >= 1 ? "\(shutter.formatted(.number.precision(.fractionLength(0...1)))) s" : "1/\(Int((1 / shutter).rounded())) s")
    }
    return parts
  }

  private func storageDescription(_ item: RemoteMediaItem) -> String {
    if item.quotaChargedBytes > 0 {
      return String(localized: "Uses \(item.quotaChargedBytes.formatted(.byteCount(style: .file))) of storage")
    }
    return item.isOriginalQuality
      ? String(localized: "Original quality, doesn't use storage") : String(localized: "Doesn't use storage")
  }
}
