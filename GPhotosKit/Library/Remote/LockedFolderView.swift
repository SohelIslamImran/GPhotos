import AVFoundation
import LocalAuthentication
import SwiftUI
import WebKit

/// The account's Google Photos Locked Folder behind Face ID, Touch ID or the
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
  @State private var showsWebManagement = false
  @State private var moveOutMediaKey: String?
  @State private var refreshAfterWebManagement = true
  @State private var browserRefresh: (library: CloudLibrary, mediaKey: String?)?
  @State private var viewerTransition = ViewerZoom()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private var session: LockedFolderSession? { access.session }

  var body: some View {
    Group {
      if let session {
        LockedFolderGrid(session: session, opened: $opened)
          .accessibilityHidden(opened != nil)
          .allowsHitTesting(opened == nil)
      } else {
        locked
      }
    }
    .navigationTitle("Locked Folder")
    .toolbar {
      if session != nil, library.supportsLockedFolderWeb {
        ToolbarItem {
          Button("Move Out of Locked Folder", systemImage: "lock.open") { openWebManagement(nil) }
        }
      }
    }
    .sheet(
      isPresented: $showsWebManagement,
      onDismiss: {
        moveOutMediaKey = nil
        if refreshAfterWebManagement, browserRefresh == nil {
          Task { await library.reconcileLockedFolder() }
        }
      }
    ) {
      if let session {
        GooglePhotosWebSheet(
          library: library, mode: .manage, moveOutMediaKey: moveOutMediaKey, lockedSession: session,
          onMoveOutConfirmed: { refreshAfterWebManagement = false },
          onOpenBrowser: { browserRefresh = (library, moveOutMediaKey) }
        ) { _ in }
      }
    }
    #if os(iOS)
      .background {
        OverFullScreen(
          key: viewerKey,
          onDismiss: {
            if moveOutMediaKey != nil, session != nil { showsWebManagement = true }
          }
        ) {
          viewer
        }
      }
    #else
      .overlay { viewer }
    #endif
    .overlay {
      if session != nil, covers { cover }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { lock() }
      if phase == .active, let pending = browserRefresh {
        browserRefresh = nil
        if pending.library === library {
          Task { await library.reconcileLockedFolder(mediaKey: pending.mediaKey) }
        }
      }
      #if os(iOS)
        // Covered (the app switcher, Control Center), nothing plays on behind it.
        session?.isCovered = phase != .active
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

  #if os(iOS)
    private var viewerKey: ViewerPresentationKey? {
      guard opened != nil, let session else { return nil }
      return ViewerPresentationKey(
        source: ObjectIdentifier(session), zoom: ObjectIdentifier(viewerTransition), reduceMotion: reduceMotion)
    }
  #endif

  @ViewBuilder private var viewer: some View {
    if let session, let opened {
      LockedFolderViewer(
        session: session, index: opened, pull: viewerTransition,
        onMoveOut: library.supportsLockedFolderWeb ? openWebManagement : nil
      ) { self.opened = nil }
    }
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

  private func openWebManagement(_ mediaKey: String?) {
    guard session != nil else { return }
    moveOutMediaKey = mediaKey
    refreshAfterWebManagement = true
    session?.stopVideo()
    #if os(iOS)
      if opened != nil {
        opened = nil
        return
      }
    #endif
    opened = nil
    showsWebManagement = true
  }

  private func lock() {
    showsWebManagement = false
    moveOutMediaKey = nil
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
  var isCovered = false
  /// The video playing, or paused, and the item it belongs to.
  private(set) var player: AVPlayer?
  private(set) var playingKey: String?
  private(set) var failedVideoKey: String?
  private(set) var startingKey: String?
  /// A photo is open: the list stays as it is until it's closed.
  @ObservationIgnored var isHeld = false
  let playback = VideoPlayback()
  @ObservationIgnored var reauthenticatedPage: WebPage?
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
    playback.pause()
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
    reauthenticatedPage?.stopLoading()
    reauthenticatedPage = nil
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

/// Uses the Library's pager while keeping Locked Folder images in the unlocked session.
struct LockedFolderViewer: View {
  let session: LockedFolderSession
  let onMoveOut: ((String) -> Void)?
  let onClose: () -> Void
  @State private var index: Int?
  @State private var chromeHidden = false
  @State private var moveOutKey: String?
  let pull: ViewerZoom
  @State private var closingPull: CGFloat?
  #if os(macOS)
    @FocusState private var isFocused: Bool
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  init(session: LockedFolderSession, index: Int, pull: ViewerZoom, onMoveOut: ((String) -> Void)?, onClose: @escaping () -> Void) {
    self.session = session
    self.pull = pull
    self.onMoveOut = onMoveOut
    self.onClose = onClose
    _index = State(initialValue: index)
  }

  static func label(for item: RemoteItemSummary) -> String {
    let kind = item.kind == .video ? String(localized: "Video") : String(localized: "Photo")
    return "\(kind), \(item.takenAt.formatted(date: .abbreviated, time: .shortened))"
  }

  var body: some View {
    GeometryReader { proxy in
      PagedViewer(count: session.items.count, index: $index, pageID: pageID) { offset in
        page(offset, size: proxy.size)
      }
      .environment(\.viewerZoom, pull)
    }
    .background {
      LockedViewerFade(pull: pull, distance: 260, closingPull: closingPull) {
        Rectangle().fill(chromeHidden ? AnyShapeStyle(.black) : AnyShapeStyle(.background))
      }
    }
    #if os(iOS)
      .ignoresSafeArea()
    #endif
    .overlay(alignment: .top) {
      if !chromeHidden {
        LockedViewerFade(pull: pull, distance: 40, closingPull: closingPull) { header }
      }
    }
    .overlay(alignment: .bottom) {
      if !chromeHidden, session.player != nil {
        LockedViewerFade(pull: pull, distance: 40, closingPull: closingPull) {
          VideoControls(playback: session.playback)
            .frame(maxWidth: 520)
            .padding(.horizontal, 26)
            #if os(macOS)
              .padding(.bottom, 12)
            #endif
        }
      }
    }
    .environment(\.colorScheme, chromeHidden ? .dark : colorScheme)
    .opacity(closingPull == nil ? 1 : 0)
    .allowsHitTesting(closingPull == nil)
    #if os(iOS)
      .accessibilityHidden(session.isCovered || session.isClosed)
      .overlay {
        if session.isCovered || session.isClosed {
          Rectangle().fill(.background).ignoresSafeArea()
        }
      }
    #endif
    .onAppear { pull.pull = 0 }
    #if os(macOS)
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
    #endif
    .onChange(of: index) { _, _ in
      session.stopVideo()
      pull.pull = 0
    }
    .onDisappear { session.stopVideo() }
    .confirmationDialog(
      "Move 1 Item Out of Locked Folder?",
      isPresented: Binding(get: { moveOutKey != nil }, set: { if !$0 { moveOutKey = nil } }),
      titleVisibility: .visible, presenting: moveOutKey
    ) { key in
      Button("Move Out") { onMoveOut?(key) }
    } message: { _ in
      Text("The item will be visible in your Google Photos library again.")
    }
  }

  private func pageID(_ index: Int) -> String {
    session.items.indices.contains(index) ? session.items[index].mediaKey : ""
  }

  @ViewBuilder private func page(_ offset: Int, size: CGSize) -> some View {
    if session.items.indices.contains(offset) {
      let item = session.items[offset]
      LockedFolderPage(
        session: session, item: item, isCurrent: offset == index, size: size, onTap: toggleChrome, onDismiss: close
      )
      #if os(macOS)
        .padding(.top, chromeHidden ? 0 : 60)
        .padding(.bottom, !chromeHidden && item.kind == .video ? 70 : 8)
      #endif
      .id(item.mediaKey)
    }
  }

  private var header: some View {
    HStack {
      headerButton("chevron.backward", label: "Back", action: close)
        .keyboardShortcut(.cancelAction)
      Spacer()
      if let index, session.items.indices.contains(index) {
        let date = session.items[index].takenAt
        VStack(spacing: 0) {
          Text(date.formatted(date: .abbreviated, time: .omitted)).font(.headline)
          Text(date.formatted(date: .omitted, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
      }
      Spacer()
      if onMoveOut != nil, let index, session.items.indices.contains(index) {
        headerButton("lock.open", label: "Move Out of Locked Folder") {
          moveOutKey = session.items[index].mediaKey
        }
      } else {
        Color.clear.frame(width: 44, height: 44)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
  }

  private func headerButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.title3).frame(width: 36, height: 36)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .accessibilityLabel(Text(label))
  }

  private func step(_ offset: Int) {
    guard let index, session.items.indices.contains(index + offset) else { return }
    self.index = index + offset
  }

  private func close() {
    guard closingPull == nil else { return }
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24), completionCriteria: .removed) {
      // The scroll view springs back after release; keep the header and grid reveal where the drag left them.
      closingPull = pull.pull
    } completion: {
      onClose()
    }
  }

  private func toggleChrome() {
    withAnimation(reduceMotion ? nil : .smooth) { chromeHidden.toggle() }
  }
}

private struct LockedViewerFade<Content: View>: View {
  let pull: ViewerZoom
  let distance: CGFloat
  let closingPull: CGFloat?
  @ViewBuilder let content: Content

  var body: some View {
    content.opacity(max(0, 1 - (closingPull ?? pull.pull) / distance))
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
      ZoomableImage(
        image: image, pixelSize: pixelSize, onTap: onTap, onDismiss: onDismiss, player: player,
        quarterTurns: session.playback.quarterTurns)
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
    .onDisappear { image = nil }
  }

  /// Any square thumbnail the grid decoded for this item.
  private var gridImage: CGImage? {
    stride(from: 1024, through: 128, by: -128).lazy.compactMap { session.cachedImage(item, side: $0, crop: true) }.first
  }
}
