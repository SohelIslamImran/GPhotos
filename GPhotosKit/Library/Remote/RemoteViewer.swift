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
  @State private var token: ImageRequestToken?
  @State private var detailToken: ImageRequestToken?
  @State private var loadedSide = 0
  @State private var player: AVPlayer?
  @State private var playerObservation: NSKeyValueObservation?
  @State private var videoFailed = false
  @State private var usesOriginal = false
  @State private var attempt = 0

  private var pixelSize: CGSize { CGSize(width: item.width ?? 0, height: item.height ?? 0) }

  var body: some View {
    ZStack {
      if let localAsset {
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
          image: image, pixelSize: pixelSize, liveText: isCurrent && item.kind != .video, onZoom: loadDetail, onTap: onTap,
          onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player
        )
      }
      if localAsset == nil && localFile == nil && (image == nil || (item.kind == .video && isCurrent && player == nil && !videoFailed)) {
        ProgressView()
      }
      if videoFailed, isCurrent {
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
    .onDisappear {
      token?.cancel()
      token = nil
      detailToken?.cancel()
      detailToken = nil
      localAsset = nil
      localFile = nil
      resolvedLocalCopy = false
      image = nil
      loadedSide = 0
      player?.pause()
      if playback.player === player { playback.attach(nil) }
      playerObservation = nil
      player = nil
    }
    .task(id: isCurrent ? attempt : -1) {
      if !resolvedLocalCopy {
        if let id = library.localAssetIDs[item.mediaKey] {
          let asset = await Task.detached(priority: .userInitiated) {
            PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
          }.value
          guard !Task.isCancelled else { return }
          localAsset = asset
        }
        if localAsset?.isHidden == true { localAsset = nil }
        if localAsset == nil, let file = library.localFiles[item.mediaKey] {
          let readable = await Task.detached(priority: .userInitiated) {
            FileManager.default.isReadableFile(atPath: file.url.path)
          }.value
          guard !Task.isCancelled else { return }
          if readable { localFile = file }
        }
        guard !Task.isCancelled else { return }
        resolvedLocalCopy = true
      }
      guard localAsset == nil, localFile == nil else { return }
      if token == nil { load(side: screenSide) }
      if isCurrent {
        await startVideo()
      } else {
        player?.pause()
        if playback.player === player { playback.attach(nil) }
      }
    }
  }

  private var screenSide: Int { Int(max(containerSize.width, containerSize.height) * displayScale) }

  private func load(side: Int) {
    let id = RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion).string
    let request = library.thumbnails.requestImage(
      id: id, pixelSize: CGSize(width: side, height: side), quality: .display
    ) { cgImage, _ in
      Task { @MainActor in
        let delivered = max(cgImage.width, cgImage.height)
        guard delivered >= loadedSide else { return }
        image = cgImage
        loadedSide = delivered
      }
    }
    if side > screenSide {
      detailToken?.cancel()
      detailToken = request
    } else {
      token = request
    }
  }

  private func loadDetail(_ zoom: CGFloat) {
    guard zoom > 1.2 else { return }
    let full = max(item.width ?? 0, item.height ?? 0)
    var wanted = Int(CGFloat(screenSide) * zoom)
    if full > 0 { wanted = min(wanted, full) }
    guard CGFloat(wanted) > CGFloat(loadedSide) * 1.25 else { return }
    load(side: wanted)
  }

  /// Both HLS and the original are streamed; opening a video never stages a full copy.
  private func startVideo() async {
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
        guard !Task.isCancelled else { return }
      }
      usesOriginal = true
    }
    do {
      let stream = try await library.videoURL(item)
      let started = try await play(url: stream.url, headers: stream.headers)
      if !started, !Task.isCancelled { videoFailed = true }
    } catch {
      if !Task.isCancelled { videoFailed = true }
    }
  }

  private func play(url: URL, headers: [String: String]) async throws -> Bool {
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    guard try await asset.load(.isPlayable) else { return false }
    try Task.checkCancellation()
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
