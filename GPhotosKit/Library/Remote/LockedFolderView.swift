import AVFoundation
import LocalAuthentication
import SwiftUI

/// The account's Google Photos Locked Folder, read only, behind Face ID, Touch ID or the
/// device passcode as Hidden is. It locks again when the app goes to the background, the
/// screen is left or the account changes, and covers itself in the app switcher.
///
/// What it shows lives only in this screen's memory while it's unlocked: never in the
/// thumbnail disk cache, the shared image cache, kept thumbnails, search, Siri, Spotlight,
/// widgets, Recently Viewed or Handoff, and there's nothing to share, save or drag.
struct LockedFolderView: View {
  static let symbol = "lock.rectangle.stack"

  let library: CloudLibrary
  @State private var access = LockedFolderAccess()
  @State private var opened: Int?
  @State private var promptedOnOpen = false
  @Environment(\.scenePhase) private var scenePhase

  private var session: LockedFolderSession? { access.session }

  var body: some View {
    Group {
      if let session {
        LockedFolderGrid(session: session, opened: $opened)
      } else {
        locked
      }
    }
    .navigationTitle("Locked Folder")
    .overlay {
      if let session, let opened {
        LockedFolderViewer(session: session, index: opened) { self.opened = nil }
      }
    }
    .overlay {
      if session != nil, covers { cover }
    }
    #if os(iOS)
      .toolbar(opened != nil ? .hidden : .automatic, for: .navigationBar, .tabBar)
    #endif
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { lock() }
      #if os(iOS)
        // Covered (the app switcher, Control Center), nothing plays on behind it.
        if phase != .active { session?.pauseVideo() }
      #endif
    }
    .onChange(of: ObjectIdentifier(library)) { lock() }
    .onChange(of: library.isRetired) { lock() }
    #if os(macOS)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        // The password prompt itself can take the focus: what it unlocks waits for the app.
        if session != nil { lock() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in lock() }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in lock() }
      .onReceive(
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification).receive(on: DispatchQueue.main)
      ) { _ in
        lock()
      }
      .onReceive(
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification).receive(on: DispatchQueue.main)
      ) { _ in
        lock()
      }
      .onReceive(
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked")).receive(
          on: DispatchQueue.main)
      ) { _ in
        lock()
      }
    #endif
    .onDisappear { lock() }
  }

  /// In the app switcher (iPhone), the screen shows a cover instead of the photos.
  private var covers: Bool {
    #if os(iOS)
      scenePhase != .active
    #else
      false
    #endif
  }

  private var locked: some View {
    ContentUnavailableView {
      Label("Locked Folder Is Locked", systemImage: "lock.fill")
    } description: {
      Text("Unlock to see the photos and videos in your Google Photos Locked Folder.")
    } actions: {
      Button("View Locked Folder") { access.unlock(library) }
        .buttonStyle(.glassProminent)
        .disabled(access.isAuthenticating)
    }
    // Asks once on the way in; after locking again, the button asks.
    .task {
      guard !promptedOnOpen, scenePhase == .active else { return }
      promptedOnOpen = true
      access.unlock(library)
    }
  }

  private var cover: some View {
    Rectangle()
      .fill(.background)
      .overlay {
        Image(systemName: "lock.fill")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
      }
      .ignoresSafeArea()
  }

  private func lock() {
    opened = nil
    access.lock()
  }
}

/// Whether the Locked Folder is open. Locking also calls off an unlock still asking, so one
/// that finishes after the screen was left or the app went away opens nothing.
@MainActor
@Observable
final class LockedFolderAccess {
  /// Set while unlocked; dropping it drops every image.
  private(set) var session: LockedFolderSession?
  private(set) var isAuthenticating = false
  @ObservationIgnored private var unlocking: Task<Void, Never>?
  @ObservationIgnored private let authenticate: @MainActor () async -> Bool

  init(authenticate: @escaping @MainActor () async -> Bool = LockedFolderAccess.authenticateOwner) {
    self.authenticate = authenticate
  }

  func unlock(_ library: CloudLibrary) {
    guard unlocking == nil, session == nil, !library.isRetired else { return }
    isAuthenticating = true
    unlocking = Task {
      let allowed = await authenticate()
      // Locked meanwhile: another unlock may already be asking.
      guard !Task.isCancelled else { return }
      unlocking = nil
      isAuthenticating = false
      if allowed, !library.isRetired { session = LockedFolderSession(library: library) }
    }
  }

  func lock() {
    unlocking?.cancel()
    unlocking = nil
    isAuthenticating = false
    session?.close()
    session = nil
  }

  private static func authenticateOwner() async -> Bool {
    nonisolated(unsafe) let context = LAContext()
    let reason = String(localized: "Unlock to see your Locked Folder.")
    let allowed = await withTaskCancellationHandler {
      (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    } onCancel: {
      context.invalidate()
    }
    #if os(macOS)
      // The app becomes active again a moment after its prompt closes. If it doesn't,
      // something else is in front and the folder stays locked.
      for _ in 0..<20 where allowed && !NSApplication.shared.isActive {
        try? await Task.sleep(for: .milliseconds(50))
      }
      return allowed && NSApplication.shared.isActive
    #else
      return allowed
    #endif
  }
}

/// One unlocked visit: the items, the images decoded for them and the video playing, in
/// memory only. Once closed it stays empty, whatever was still on its way.
@MainActor
@Observable
final class LockedFolderSession {
  let library: CloudLibrary
  private(set) var items: [RemoteItemSummary] = []
  private(set) var isLoaded = false
  private(set) var loadFailed = false
  private(set) var isClosed = false
  /// The video playing, or paused, and the item it belongs to.
  private(set) var player: AVPlayer?
  private(set) var playingKey: String?
  private(set) var failedVideoKey: String?
  private(set) var startingKey: String?
  /// A photo is open: the list stays as it is until it's closed.
  @ObservationIgnored var isHeld = false
  let playback = VideoPlayback()
  /// Images that came back, and requests Google refused or that failed.
  private(set) var loadedImages = 0
  private(set) var failedImages = 0
  /// Bumped by Try Again, so every cell asks again.
  private(set) var attempt = 0
  private let images = NSCache<NSString, ImageBox>()
  @ObservationIgnored private var load: Task<Void, Never>?
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private let makePlayer: @MainActor (RemoteItemSummary) async throws -> AVPlayer

  private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  init(library: CloudLibrary, makePlayer: (@MainActor (RemoteItemSummary) async throws -> AVPlayer)? = nil) {
    self.library = library
    self.makePlayer = makePlayer ?? { try await Self.player(for: $0, in: library) }
    images.totalCostLimit = 64 << 20
    loadItems()
  }

  /// The folder's newer contents, as the sync brings them.
  func reload() {
    guard !isClosed else { return }
    loadItems()
  }

  private func loadItems() {
    loadFailed = false
    load?.cancel()
    load = Task { [weak self, library] in
      let items = try? await library.lockedItems()
      guard let self, !isClosed, !Task.isCancelled, !isHeld else { return }
      if let items {
        if self.items != items { self.items = items }
        isLoaded = true
      } else if !isLoaded {
        loadFailed = true
      }
    }
  }

  /// Google sent nothing for any item it was asked for.
  var isRefused: Bool { failedImages >= 3 && loadedImages == 0 }

  func cachedImage(_ item: RemoteItemSummary, side: Int, crop: Bool) -> CGImage? {
    images.object(forKey: Self.key(item, side: side, crop: crop))?.image
  }

  func image(_ item: RemoteItemSummary, side: Int, crop: Bool) async -> CGImage? {
    guard !isClosed else { return nil }
    if let cached = cachedImage(item, side: side, crop: crop) { return cached }
    do {
      let image = try await library.lockedImage(item, side: side, crop: crop)
      guard !isClosed, !Task.isCancelled else { return nil }
      images.setObject(ImageBox(image), forKey: Self.key(item, side: side, crop: crop), cost: image.bytesPerRow * image.height)
      loadedImages += 1
      return image
    } catch {
      if !(error is CancellationError), !Task.isCancelled { failedImages += 1 }
      return nil
    }
  }

  func retry() {
    loadedImages = 0
    failedImages = 0
    attempt &+= 1
    if !isLoaded { loadItems() }
  }

  func play(_ item: RemoteItemSummary) {
    guard !isClosed else { return }
    stopVideo()
    failedVideoKey = nil
    startingKey = item.mediaKey
    starting = Task { [weak self, makePlayer] in
      do {
        let player = try await makePlayer(item)
        guard let self, !isClosed, !Task.isCancelled else { return }
        starting = nil
        startingKey = nil
        // Only on this screen: no AirPlay, and (with no AVKit player) no Picture in Picture
        // or Now Playing.
        player.allowsExternalPlayback = false
        self.player = player
        playingKey = item.mediaKey
        playback.attach(player)
        player.play()
      } catch {
        guard let self, !isClosed, !Task.isCancelled else { return }
        starting = nil
        startingKey = nil
        failedVideoKey = item.mediaKey
      }
    }
  }

  /// Also calls off one about to start, and a scrub that would play on when it ends.
  func pauseVideo() {
    starting?.cancel()
    starting = nil
    startingKey = nil
    guard let player else { return }
    player.pause()
    playback.attach(nil)
    playback.attach(player)
  }

  func stopVideo() {
    pauseVideo()
    playback.attach(nil)
    player?.replaceCurrentItem(with: nil)
    player = nil
    playingKey = nil
  }

  private static func player(for item: RemoteItemSummary, in library: CloudLibrary) async throws -> AVPlayer {
    let stream = try await library.lockedVideo(item)
    let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
    guard try await asset.load(.isPlayable) else { throw GPhotosError.httpError(status: -1, body: "Unplayable video") }
    return AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }

  func close() {
    isClosed = true
    load?.cancel()
    stopVideo()
    images.removeAllObjects()
    items = []
  }

  private static func key(_ item: RemoteItemSummary, side: Int, crop: Bool) -> NSString {
    "\(item.mediaKey)-\(item.contentVersion)-\(side)\(crop ? "c" : "")" as NSString
  }
}

private struct LockedFolderGrid: View {
  let session: LockedFolderSession
  @Binding var opened: Int?
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let columns = Self.columnCount(for: proxy.size.width)
      let side = (proxy.size.width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing
        ) {
          ForEach(session.items) { item in
            Button {
              // The list may have changed under the tap.
              guard let current = session.items.firstIndex(where: { $0.mediaKey == item.mediaKey }) else { return }
              session.isHeld = true
              opened = current
            } label: {
              LockedFolderCell(session: session, item: item, side: Self.requestSide(side * displayScale))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .overlay {
      if session.isLoaded, session.items.isEmpty, isFinding {
        ProgressView("Loading Locked Folder…")
      } else if session.isLoaded, session.items.isEmpty {
        ContentUnavailableView(
          "No Items", systemImage: LockedFolderView.symbol,
          description: Text("Items in your Locked Folder appear here once Google Photos lists them in the sync."))
      } else if session.loadFailed {
        ContentUnavailableView {
          Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } actions: {
          Button("Try Again") { session.retry() }.buttonStyle(.glassProminent)
        }
      } else if !session.isLoaded {
        ProgressView()
      }
    }
    // Not while a photo is open: it would change under the viewer.
    .task(id: Contents(revision: session.library.revision, isViewing: opened != nil)) {
      session.isHeld = opened != nil
      if opened == nil { session.reload() }
    }
    .task { session.library.refresh() }
    .safeAreaInset(edge: .bottom) {
      if isFinding, !session.items.isEmpty {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Loading more items…").font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
        .padding(.bottom, 8)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if session.isRefused {
        VStack(spacing: 8) {
          Text("Google Photos didn't send these photos. Try again later.")
            .multilineTextAlignment(.center)
          Button("Try Again", systemImage: "arrow.clockwise") { session.retry() }
            .buttonStyle(.glass)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding()
      }
    }
  }

  private struct Contents: Hashable {
    let revision: Int
    let isViewing: Bool
  }

  /// Google's list of the account is still coming in.
  private var isFinding: Bool { session.library.isSyncing && !session.library.syncState.initialSyncDone }

  private static let spacing: CGFloat = 2

  private static func columnCount(for width: CGFloat) -> Int {
    #if os(iOS)
      max(3, Int(width / 130))
    #else
      max(3, Int(width / 160))
    #endif
  }

  /// Rounded up to a few sizes, so a resized window asks for what it already has.
  private static func requestSide(_ pixels: CGFloat) -> Int {
    max(128, Int((pixels / 128).rounded(.up)) * 128)
  }
}

struct LockedFolderCell: View {
  struct Request: Equatable {
    let side: Int
    let attempt: Int
    let version: Int
  }

  let session: LockedFolderSession
  let item: RemoteItemSummary
  let side: Int
  @State private var image: CGImage?
  @State private var imageVersion = 0
  @State private var failed = false

  var body: some View {
    Rectangle()
      .fill(.fill.tertiary)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else if failed {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if item.kind == .video, let duration = item.duration {
          Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
      }
      .clipped()
      .contentShape(.rect)
      .accessibilityElement()
      .accessibilityLabel(LockedFolderViewer.label(for: item))
      .task(id: Request(side: side, attempt: session.attempt, version: item.contentVersion)) {
        failed = false
        if imageVersion != item.contentVersion { image = nil }
        let updated = await session.image(item, side: side, crop: true)
        guard !Task.isCancelled, !session.isClosed else { return }
        if let updated {
          image = updated
          imageVersion = item.contentVersion
        }
        failed = updated == nil
      }
  }
}

/// The Locked Folder's own viewer: the photo fitted to the screen with native zoom, paged
/// by swiping (iPhone) or the arrow keys (Mac). It has no Info, Share or other actions.
struct LockedFolderViewer: View {
  let session: LockedFolderSession
  let onClose: () -> Void
  @State private var index: Int
  @State private var chromeHidden = false
  #if os(macOS)
    @FocusState private var isFocused: Bool
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(session: LockedFolderSession, index: Int, onClose: @escaping () -> Void) {
    self.session = session
    self.onClose = onClose
    _index = State(initialValue: index)
  }

  static func label(for item: RemoteItemSummary) -> String {
    let kind = item.kind == .video ? String(localized: "Video") : String(localized: "Photo")
    return "\(kind), \(item.takenAt.formatted(date: .abbreviated, time: .shortened))"
  }

  var body: some View {
    GeometryReader { proxy in
      pages(size: proxy.size)
    }
    .background(chromeHidden ? Color.black : Color.clear)
    .background(.background)
    .ignoresSafeArea()
    .overlay(alignment: .top) {
      if !chromeHidden { header }
    }
    .overlay(alignment: .bottom) {
      if !chromeHidden, session.player != nil {
        VideoControls(playback: session.playback)
          .frame(maxWidth: 520)
          .padding(.horizontal, 26)
          .padding(.bottom, 40)
      }
    }
    #if os(macOS)
      .overlay {
        HStack {
          stepButton(-1, symbol: "chevron.left", label: "Previous")
          Spacer()
          stepButton(1, symbol: "chevron.right", label: "Next")
        }
        .padding()
        .opacity(chromeHidden ? 0 : 1)
      }
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .onAppear { isFocused = true }
      .onKeyPress(.leftArrow) {
        step(-1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        step(1)
        return .handled
      }
      .onKeyPress(.escape) {
        onClose()
        return .handled
      }
    #endif
    .onChange(of: session.items.count) { _, count in
      if count == 0 { onClose() } else if index >= count { index = count - 1 }
    }
  }

  @ViewBuilder private func pages(size: CGSize) -> some View {
    #if os(iOS)
      TabView(selection: $index) {
        ForEach(Array(session.items.enumerated()), id: \.element.id) { offset, item in
          LockedFolderPage(
            session: session, item: item, isCurrent: offset == index, size: size, onTap: toggleChrome, onDismiss: onClose
          )
          .tag(offset)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
    #else
      if session.items.indices.contains(index) {
        LockedFolderPage(
          session: session, item: session.items[index], isCurrent: true, size: size, onTap: toggleChrome, onDismiss: onClose
        )
        .id(session.items[index].id)
      }
    #endif
  }

  private var header: some View {
    HStack {
      Button(action: onClose) {
        Label("Close", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      #if os(iOS)
        .controlSize(.large)
      #endif
      .keyboardShortcut(.cancelAction)
      Spacer()
      if session.items.indices.contains(index) {
        VStack(spacing: 0) {
          Text(session.items[index].takenAt.formatted(date: .abbreviated, time: .omitted)).font(.headline)
          Text(session.items[index].takenAt.formatted(date: .omitted, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect()
      }
      Spacer()
      // Balances the close button, so the date stays centred.
      Color.clear.frame(width: 44, height: 44)
    }
    .padding(.horizontal)
    #if os(iOS)
      .padding(.top, 8)
    #else
      .padding(.top, 60)
    #endif
  }

  #if os(macOS)
    private func stepButton(_ offset: Int, symbol: String, label: LocalizedStringKey) -> some View {
      Button {
        step(offset)
      } label: {
        Label(label, systemImage: symbol)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .disabled(!session.items.indices.contains(index + offset))
    }
  #endif

  private func step(_ offset: Int) {
    let next = index + offset
    guard session.items.indices.contains(next) else { return }
    index = next
  }

  private func toggleChrome() {
    withAnimation(reduceMotion ? nil : .smooth) { chromeHidden.toggle() }
  }
}

private struct LockedFolderPage: View {
  let session: LockedFolderSession
  let item: RemoteItemSummary
  let isCurrent: Bool
  let size: CGSize
  let onTap: () -> Void
  let onDismiss: () -> Void
  @State private var image: CGImage?
  @State private var failed = false
  @State private var isLoadingFull = false
  @Environment(\.displayScale) private var displayScale

  private var player: AVPlayer? { session.playingKey == item.mediaKey ? session.player : nil }
  private var videoFailed: Bool { session.failedVideoKey == item.mediaKey }
  private var pixelSize: CGSize { CGSize(width: item.width ?? 0, height: item.height ?? 0) }

  /// The viewer's sizes, as for any Google Photos item.
  private var side: Int {
    let longest = max(size.width, size.height) * displayScale
    return GoogleThumbnailSource.requestSide(for: CGSize(width: longest, height: longest), quality: .display)
  }

  var body: some View {
    ZStack {
      ZoomableImage(image: image, pixelSize: pixelSize, onTap: onTap, onDismiss: onDismiss, player: player)
      if isCurrent, session.startingKey == item.mediaKey {
        ViewerLoadingIndicator(isLoading: true)
      } else if image == nil, player == nil {
        if failed {
          Label("Couldn't Load", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else if isCurrent {
          ViewerLoadingIndicator(isLoading: true)
        }
      } else if isCurrent, player == nil, isLoadingFull {
        ViewerLoadingIndicator(isLoading: true)
      } else if isCurrent, player != nil, session.playback.isBuffering {
        ViewerLoadingIndicator(isLoading: true)
      }
      if item.kind == .video, isCurrent, player == nil, session.startingKey != item.mediaKey {
        Button {
          session.play(item)
        } label: {
          Label(videoFailed ? "Couldn't Play Video" : "Play", systemImage: videoFailed ? "exclamationmark.triangle" : "play.fill")
        }
        .labelStyle(.iconOnly)
        .font(.title)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .disabled(videoFailed)
      }
    }
    .accessibilityLabel(LockedFolderViewer.label(for: item))
    .task(id: isCurrent) {
      // The grid's thumbnail first, soft, while the screen-sized photo loads.
      if image == nil {
        image = session.cachedImage(item, side: side, crop: false) ?? gridImage
      }
      guard isCurrent else { return }
      isLoadingFull = true
      defer { isLoadingFull = false }
      if let full = await session.image(item, side: side, crop: false) {
        image = full
      } else if image == nil, !Task.isCancelled {
        failed = true
      }
    }
    .onChange(of: isCurrent) { _, current in
      if !current { session.stopVideo() }
    }
    .onDisappear {
      if isCurrent { session.stopVideo() }
      image = nil
    }
  }

  /// Any square thumbnail the grid decoded for this item.
  private var gridImage: CGImage? {
    stride(from: 1024, through: 128, by: -128).lazy.compactMap { session.cachedImage(item, side: $0, crop: true) }.first
  }
}
