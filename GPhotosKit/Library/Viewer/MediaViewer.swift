import AVKit
import AppIntents
import Photos
import SwiftUI

/// One item the viewer can show: a photo-library asset, a Google Photos item, or a file in
/// a backed-up folder (with its Google Photos copy, once backed up).
public enum ViewerItem {
  case device(PHAsset, backup: PhotoGridBadges.Backup?)
  case cloud(RemoteItemSummary, library: CloudLibrary, isOnDevice: Bool)
  case file(FolderItemInfo, backup: PhotoGridBadges.Backup?, cloud: (item: RemoteItemSummary, library: CloudLibrary)?)

  var date: Date? {
    switch self {
    case .device(let asset, _): asset.creationDate
    case .cloud(let item, _, _): item.takenAt
    case .file(let file, _, let copy): copy?.item.takenAt ?? file.date
    }
  }

  var isVideo: Bool {
    switch self {
    case .device(let asset, _): asset.mediaType == .video
    case .cloud(let item, _, _): item.kind == .video
    case .file(let file, _, _): file.isVideo
    }
  }

  /// The item's index id, which is also its `PhotoEntity` id. A backed-up folder file is
  /// its Google Photos copy, as in search.
  var indexID: String {
    switch self {
    case .device(let asset, _): asset.localIdentifier
    case .cloud(let item, _, _): LibraryIndexer.searchID(cloudMediaKey: item.mediaKey)
    case .file(let file, _, let copy): copy.map { LibraryIndexer.searchID(cloudMediaKey: $0.item.mediaKey) } ?? file.id
    }
  }
}

extension ViewerItem {
  /// The file a drag out of the grid delivers.
  var dragItem: PhotoGridDragItem {
    switch self {
    case .device(let asset, _):
      let resource = PHAssetResource.assetResources(for: asset).first {
        $0.type == (asset.mediaType == .video ? .video : .photo)
      }
      return PhotoGridDragItem(
        fileName: resource.map(SharedAsset.filename(of:)) ?? "Photo", isVideo: asset.mediaType == .video
      ) { try await SharedAsset(asset).export() }
    case .cloud(let item, let library, _):
      return PhotoGridDragItem(
        fileName: item.fileName.isEmpty ? item.mediaKey : item.fileName, isVideo: item.kind == .video
      ) { try await library.download(item) }
    case .file(let file, _, _):
      return PhotoGridDragItem(fileName: file.fileName, isVideo: file.isVideo) { file.url }
    }
  }
}

/// Part of the viewer that fades with the zoom from the grid and as the photo is pulled
/// down: the background goes first, the controls with the first few points of a pull.
/// Only this reads the zoom's progress, so a pull redraws nothing else.
private struct ZoomFade<Content: View>: View {
  let zoom: ViewerZoom?
  var isBackground = false
  @ViewBuilder let content: Content

  var body: some View {
    content.opacity(opacity)
  }

  private var opacity: Double {
    guard let zoom else { return 1 }
    let pulled = Double(max(0, zoom.pull))
    return zoom.progress * max(0, 1 - pulled / (isBackground ? 260 : 40))
  }
}

/// A grid data source the viewer can page through.
@MainActor
public protocol MediaViewerSource: PhotoGridDataSource {
  var badgeToken: Int { get }
  func viewerItem(at index: Int) -> ViewerItem?
  /// Where the item with grid id `id` is now; `near` is where it was.
  func index(ofItemID id: String, near: Int) -> Int?
  /// The Google Photos copy of the device item at `index`, which Delete also trashes.
  func cloudCopy(at index: Int) -> (item: RemoteItemSummary, library: CloudLibrary)?
}

extension MediaViewerSource {
  public func cloudCopy(at index: Int) -> (item: RemoteItemSummary, library: CloudLibrary)? { nil }

  /// Looks around where the item was: arrivals and removals near it move it a little.
  public func index(ofItemID id: String, near: Int) -> Int? {
    let count = itemCount
    for distance in 0...256 {
      for index in [near - distance, near + distance] where index >= 0 && index < count {
        if itemID(at: index) == id { return index }
      }
    }
    return nil
  }
}

/// The full-screen viewer for any mix of device and Google Photos items. Pages are created
/// lazily; each fits the whole photo, starts from what's cached, sharpens to screen size
/// and loads more pixels as you zoom. Pages drop their images when they scroll away.
public struct MediaViewer: View {
  let source: any MediaViewerSource
  let onClose: () -> Void
  struct PageSelection {
    let index: Int
    let id: String
    let cloudID: String?

    @MainActor func position(in source: any MediaViewerSource) -> Int? {
      let count = source.itemCount
      guard count > 0 else { return nil }
      if index < count, source.itemID(at: index) == id { return index }
      return source.index(ofItemID: id, near: index)
        ?? cloudID.flatMap { source.index(ofItemID: $0, near: index) }
        ?? min(index, count - 1)
    }

    @MainActor init(index: Int, source: any MediaViewerSource) {
      self.index = index
      id = source.itemID(at: index)
      if id.hasPrefix(FolderItemInfo.idPrefix), case .file(_, _, let copy) = source.viewerItem(at: index) {
        cloudID = copy?.item.thumbnailID
      } else {
        cloudID = nil
      }
    }
  }

  struct PageLocation: Equatable {
    let index: Int
    let id: String
  }

  private var pageLocation: PageLocation? {
    position.map { PageLocation(index: $0, id: source.itemID(at: $0)) }
  }

  @State private var pageSelection: PageSelection?
  private var position: Int? {
    get { pageSelection?.position(in: source) }
    nonmutating set { pageSelection = newValue.map { PageSelection(index: $0, source: source) } }
  }
  private var positionBinding: Binding<Int?> { Binding(get: { position }, set: { position = $0 }) }
  @State private var chromeHidden = false
  #if os(iOS)
    @State private var filmstrip = FilmstripLink()
  #endif
  @State private var showsInfo = false
  @State private var confirmsDelete = false
  /// What the open delete dialog asks about.
  @State private var deletingTarget: String?
  /// The item just deleted, shrinking away before the next one slides in.
  @State private var removingID: String?
  @State private var video = VideoPlayback()
  @State private var pageSize: CGSize = .zero
  @State private var neighborRequests = ViewerNeighborRequests()
  @State private var playingLive: String?
  @State private var lockedFolderMove = LockedFolderMove()
  @State private var errorMessage: String?
  @State private var isBusy = false
  #if os(macOS)
    /// Where the viewer is in the window, and the room its header and toolbar take.
    @State private var viewerFrame: CGRect = .zero
    @State private var headerBottom: CGFloat = 0
    /// Where the content area starts, right of a sidebar the viewer extends under.
    @State private var contentLeading: CGFloat = 0
    @State private var infoHeight: CGFloat = 300
  #endif
  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var background: Color {
    guard !chromeHidden else { return .black }
    #if os(iOS)
      return Color(uiColor: .systemBackground)
    #else
      return Color(nsColor: .windowBackgroundColor)
    #endif
  }

  /// Told which item is showing, so the grid can zoom back to it on close.
  let onIndexChange: (Int) -> Void

  /// Drives the zoom from and back to the grid (iOS), if the viewer was opened with one.
  let zoom: ViewerZoom?

  /// The open item's date and details, for the window's title (Mac).
  let onTitleChange: ((title: String, subtitle: String)) -> Void

  public init(
    source: any MediaViewerSource, startIndex: Int, zoom: ViewerZoom? = nil,
    onIndexChange: @escaping (Int) -> Void = { _ in },
    onTitleChange: @escaping ((title: String, subtitle: String)) -> Void = { _ in }, onClose: @escaping () -> Void
  ) {
    self.source = source
    self.zoom = zoom
    self.onTitleChange = onTitleChange
    self.onClose = onClose
    self.onIndexChange = onIndexChange
    _pageSelection = State(initialValue: PageSelection(index: startIndex, source: source))
  }

  private var current: ViewerItem? {
    _ = source.badgeToken
    return position.flatMap(source.viewerItem(at:))
  }

  private var currentShareIdentity: [ThumbnailIdentity] {
    position.map { [source.thumbnailIdentity(at: $0)] } ?? []
  }

  public var body: some View {
    let item = current
    pager
      .onGeometryChange(for: CGSize.self, of: \.size) { pageSize = $0 }
      .background {
        ZoomFade(zoom: zoom, isBackground: true) { background }
          #if os(macOS)
            .onGeometryChange(for: CGRect.self) {
              $0.frame(in: .global)
            } action: {
              viewerFrame = $0
            }
          #endif
      }
      .ignoresSafeArea()
      .overlay(alignment: .top) {
        #if os(iOS)
          if !chromeHidden {
            ZoomFade(zoom: zoom) { header(item) }
              .transition(.opacity)
          }
        #else
          // The controls are in the window's toolbar; the photo fits below it.
          Color.clear.frame(height: 1)
            .onGeometryChange(for: CGPoint.self) {
              $0.frame(in: .global).origin
            } action: {
              headerBottom = $0.y
              contentLeading = $0.x
            }
            .allowsHitTesting(false)
        #endif
      }
      .overlay(alignment: .bottom) {
        if !chromeHidden {
          ZoomFade(zoom: zoom) {
            VStack(spacing: Self.controlsSpacing) {
              if item?.isVideo == true {
                VideoControls(playback: video).frame(height: Self.videoControlsHeight).padding(.horizontal, 26)
                  #if os(iOS)
                    .modifier(DisabledWhileScrubbing(link: filmstrip))
                  #endif
              }
              VStack(spacing: Self.controlsSpacing) {
                #if os(iOS)
                  if source.itemCount > 1 {
                    Filmstrip(source: source, index: positionBinding, link: filmstrip, thumbnailRevision: source.thumbnailRevision)
                      .frame(height: Filmstrip.height)
                      // Inset from the screen's edges and fading out at both ends, as in Photos.
                      .mask {
                        LinearGradient(
                          stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.94), .init(color: .clear, location: 1),
                          ], startPoint: .leading, endPoint: .trailing)
                      }
                      .padding(.horizontal, 18)
                  }
                #endif
                #if os(iOS)
                  // Actions are for the open item, which a moving strip has left behind.
                  toolbar(item).modifier(DisabledWhileScrubbing(link: filmstrip))
                #endif
              }
            }
            #if os(macOS)
              .padding(.bottom, 16)
            #endif
          }
          .transition(.opacity)
        }
      }
      .environment(\.viewerZoom, zoom)
      // With the controls hidden, photos sit on black, as in Photos.
      .environment(\.colorScheme, chromeHidden ? .dark : colorScheme)
      .animation(reduceMotion ? nil : .smooth, value: chromeHidden)
      #if os(iOS)
        // A sheet, which is what an inspector becomes on iPhone anyway; an inspector also
        // puts an opaque background behind the viewer, which hides the grid while it zooms.
        .sheet(isPresented: $showsInfo) { info(item).presentationDetents([.medium, .large]) }
      #else
        // A panel floating over the photo, as Photos' Info window does. An inspector would add
        // a column to the window and move every toolbar item, which flickers as it opens.
        .overlay(alignment: .topTrailing) {
          if showsInfo {
            info(item)
            .id(position.map { source.itemID(at: $0) })
            .scrollContentBackground(.hidden)
            // As tall as what it shows, up to a limit; then it scrolls.
            .onScrollGeometryChange(for: CGFloat.self) {
              $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom
            } action: { _, height in
              infoHeight = height
            }
            .frame(width: 320, height: min(max(infoHeight, 120), 560))
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            .padding(12)
            // Keep native caption fields at their measured size throughout the transition.
            .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: showsInfo)
        .toolbar { macToolbar(item) }
        .task(id: [macTitle(item), macSubtitle(item)]) {
          guard !Task.isCancelled else { return }
          onTitleChange((macTitle(item), macSubtitle(item)))
        }
        .onChange(of: deleteTarget) { confirmsDelete = false }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
          Button(deleteButtonTitle, role: .destructive) { deleteCurrent() }
          if currentCloudCopy != nil {
            Button("Delete from This Device", role: .destructive) { deleteCurrent(includingCopy: false) }
          }
        } message: {
          Text(deleteMessage)
        }
      #endif
      .alert(
        "Couldn't Finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(errorMessage ?? "")
      }
      .modifier(LockedFolderMovePresentation(move: lockedFolderMove))
      .sensoryFeedback(.impact(weight: .light), trigger: playingLive) { _, playing in playing != nil }
      #if os(iOS)
        // As in Photos, a video that starts by itself tucks the controls away after a moment;
        // a tap brings them back. The Mac keeps them, as there's no tap to do that.
        .task(id: video.autoplayCount) {
          guard video.autoplayCount > 0 else { return }
          let player = video.player
          try? await Task.sleep(for: .seconds(2))
          guard !Task.isCancelled, player === video.player, video.isPlaying, !showsInfo, !filmstrip.isScrubbing else { return }
          withAnimation(reduceMotion ? nil : .smooth) { chromeHidden = true }
        }
      #endif
      #if DEBUG && os(macOS)
        // `-UIViewerInfo` opens and closes Info on a timer, for review.
        .task {
          guard UserDefaults.standard.bool(forKey: "UIViewerInfo") else { return }
          for _ in 0..<3 {
            try? await Task.sleep(for: .seconds(2))
            showsInfo.toggle()
          }
        }
      #endif
      #if DEBUG && os(iOS)
        .task {
          guard UserDefaults.standard.string(forKey: "UIScreen") == "cloudFilmstripStress" else { return }
          try? await Task.sleep(for: .seconds(2))
          filmstrip.runStress(seconds: 6)
        }
      #endif
      .onChange(of: pageLocation, initial: true) { previous, current in
        // After a deletion the neighbour becomes the selection, even at the same index.
        if let current, pageSelection?.id != current.id || pageSelection?.index != current.index {
          position = current.index
        }
        if previous?.id != current?.id {
          playingLive = nil
          removingID = nil
          video.attach(nil)
        }
        if let current { onIndexChange(current.index) }
      }

      // Siri knows which photo is on screen ("share this with Sam", "add this to Trip").
      .userActivity(SiriLibrary.viewingActivityType, isActive: item != nil) { activity in
        guard let item else { return }
        activity.title = item.date?.formatted(date: .abbreviated, time: .shortened)
        activity.appEntityIdentifier = EntityIdentifier(for: PhotoEntity.self, identifier: item.indexID)
      }
      .onChange(of: item?.indexID, initial: true) {
        if case .device(let asset, _) = item { RecentlyViewed.record(asset.localIdentifier) }
      }
      .onChange(of: neighborWindow, initial: true) { _, window in
        neighborRequests.update(window.adjacent, keeping: window.current)
      }
      .onDisappear {
        video.attach(nil)
        neighborRequests.update([])
      }
      .onChange(of: source.itemCount) { _, count in
        if count == 0 { onClose() }
      }
      #if os(macOS)
        .background {
          ViewerKeyboardEvents { action in
            switch action {
            case .previous: _ = step(-1)
            case .next: _ = step(1)
            case .escape: if showsInfo { showsInfo = false } else { onClose() }
            case .space: onClose()
            }
          }
        }
      #endif
  }

  @ViewBuilder private var pager: some View {
    #if os(iOS)
      PagedViewer(
        count: source.itemCount, index: positionBinding, onSwipe: { filmstrip.pagerMoved(to: $0) },
        onTouch: { filmstrip.pagerTouched() },
        pageID: source.itemID(at:), locate: { source.index(ofItemID: $0, near: $1) }
      ) { index in
        page(index, size: pageSize)
      }
      .opacity(zoom.map { $0.hidesPages ? 0 : $0.progress } ?? 1)
      .overlay { ScrubPreview(link: filmstrip).ignoresSafeArea() }
    #else
      PagedViewer(count: source.itemCount, index: positionBinding) { index in
        page(index, size: pageSize)
      }
    #endif
  }

  private struct NeighborWindow: Equatable {
    var current: ViewerNeighborRequests.Target? = nil
    var adjacent: [ViewerNeighborRequests.Target] = []
  }

  private var neighborWindow: NeighborWindow {
    guard let position, pageSize.width > 0, pageSize.height > 0 else { return NeighborWindow() }
    return NeighborWindow(current: neighborTarget(at: position), adjacent: [position - 1, position + 1].compactMap(neighborTarget(at:)))
  }

  private func neighborTarget(at index: Int) -> ViewerNeighborRequests.Target? {
    guard index >= 0, index < source.itemCount else { return nil }
    switch source.viewerItem(at: index) {
    case .device(let asset, _):
      PhotoKitImageSource.shared.remember(asset)
      let pixels = ViewerImage.fittedPixels(
        CGSize(width: asset.pixelWidth, height: asset.pixelHeight), in: pageSize, scale: displayScale)
      return .init(identity: PhotoKitImageSource.identity(for: asset), pixels: pixels, isFile: false)
    case .file(let file, _, _):
      let side = max(pageSize.width, pageSize.height) * displayScale
      return .init(identity: file.thumbnailIdentity, pixels: CGSize(width: side, height: side), isFile: true)
    default:
      return nil
    }
  }

  @ViewBuilder private func info(_ item: ViewerItem?) -> some View {
    switch item {
    case .device(let asset, let backup): PhotoInfoView(asset: asset, backup: backup)
    case .cloud(let item, let library, let isOnDevice):
      RemoteInfoView(library: library, summary: item, isOnDevice: isOnDevice)
    case .file(let file, let backup, let copy):
      FileInfoView(item: file, backup: backup, takenAt: copy?.item.takenAt ?? file.date)
    case nil: EmptyView()
    }
  }

  // Spacing and sizes measured from Photos on iPhone.
  private static let controlsSpacing: CGFloat = 16
  private static let videoControlsHeight: CGFloat = 54

  #if os(macOS)
    /// A little air between the photo and the controls.
    private static let fitGap: CGFloat = 8

    /// The photo fits below the window's toolbar, where the Mac's controls are. A video also
    /// leaves room for its controls, counted here since those are only on screen while it's
    /// the current page.
    private func fitInsets(isVideo: Bool) -> EdgeInsets {
      guard headerBottom > 0 else { return EdgeInsets() }
      let videoRoom = isVideo ? Self.videoControlsHeight + 16 : 0
      return EdgeInsets(
        top: max(0, headerBottom - viewerFrame.minY) + Self.fitGap, leading: max(0, contentLeading - viewerFrame.minX),
        bottom: videoRoom + Self.fitGap, trailing: 0)
    }
  #endif

  private func page(_ index: Int, size: CGSize) -> some View {
    let id = source.itemID(at: index)
    let item = source.viewerItem(at: index)
    let identity = source.thumbnailIdentity(at: index)
    let removing = removingID == id
    return pageContent(item, at: index, size: size)
      .environment(\.viewerItemID, id)
      .environment(\.viewerThumbnailIdentity, identity)
      .environment(\.viewerNeighbors, neighborRequests)
      #if os(iOS)
        .environment(\.filmstripLink, filmstrip)
      #else
        .padding(fitInsets(isVideo: item?.isVideo == true))
      #endif
      .id(identity)
      // As in Photos, a deleted photo shrinks and blurs away.
      .scaleEffect(removing && !reduceMotion ? 0.6 : 1)
      .blur(radius: removing && !reduceMotion ? 20 : 0)
      .opacity(removing ? 0 : 1)
      // Pages are separate hosting controllers, which a transaction doesn't reach.
      .animation(.smooth(duration: 0.3), value: removing)
  }

  @ViewBuilder private func pageContent(_ item: ViewerItem?, at index: Int, size: CGSize) -> some View {
    let isCurrent = position == index
    let onTap = { withAnimation(reduceMotion ? nil : .smooth) { chromeHidden.toggle() } }
    switch item {
    case .device(let asset, _):
      let page = DeviceViewerPage(
        asset: asset, label: source.accessibilityLabel(at: index), containerSize: size, displayScale: displayScale,
        isCurrent: isCurrent, playsLive: playingLive == asset.localIdentifier, onTap: onTap, onDismiss: close,
        onSwipeUp: { if !isScrubbing { showsInfo = true } },
        onLiveEnd: { playingLive = nil }, playback: video)
      if asset.mediaSubtypes.contains(.photoLive) {
        // Press and hold plays a Live Photo, as in Photos; zooming and Live Text still work.
        page.simultaneousGesture(
          LongPressGesture(minimumDuration: 0.3).onEnded { _ in
            if !isScrubbing { playingLive = asset.localIdentifier }
          })
      } else {
        page
      }
    case .cloud(let item, let library, _):
      RemoteViewerPage(
        library: library, item: item, containerSize: size, displayScale: displayScale, isCurrent: isCurrent,
        onTap: onTap, onDismiss: close, onSwipeUp: { if !isScrubbing { showsInfo = true } }, playback: video)
    case .file(let file, _, _):
      FileViewerPage(
        item: file, containerSize: size, displayScale: displayScale, isCurrent: isCurrent, onTap: onTap,
        onDismiss: close, onSwipeUp: { if !isScrubbing { showsInfo = true } }, playback: video)
    case nil:
      Color.clear
    }
  }

  private func close() { onClose() }

  private var isCloud: Bool {
    if case .cloud = current { return true }
    return false
  }

  /// A Google Photos item in Trash, which Delete removes for good.
  private var isTrashed: Bool {
    if case .cloud(let item, _, _) = current { return item.trashedAt != nil }
    return false
  }

  private var deleteTitle: String {
    if isTrashed { return String(localized: "Delete Forever?") }
    if isCloud { return String(localized: "Move to Trash?") }
    return current?.isVideo == true ? String(localized: "Delete This Video?") : String(localized: "Delete This Photo?")
  }

  /// The backed-up copy of the device item shown, if it has one.
  private var currentCloudCopy: (item: RemoteItemSummary, library: CloudLibrary)? {
    guard case .device = current, let position else { return nil }
    return source.cloudCopy(at: position)
  }

  private var deleteButtonTitle: String {
    if isTrashed { return String(localized: "Delete Forever") }
    if currentCloudCopy != nil { return String(localized: "Delete Everywhere") }
    if isCloud { return String(localized: "Move to Trash") }
    return current?.isVideo == true ? String(localized: "Delete Video") : String(localized: "Delete Photo")
  }

  private var deleteMessage: String {
    let isVideo = current?.isVideo == true
    if isTrashed {
      return isVideo
        ? String(localized: "This video will be deleted from Google Photos on all your devices. This can't be undone.")
        : String(localized: "This photo will be deleted from Google Photos on all your devices. This can't be undone.")
    }
    if isCloud {
      return isVideo
        ? String(localized: "This video will move to the Trash in Google Photos. You can restore it for 60 days.")
        : String(localized: "This photo will move to the Trash in Google Photos. You can restore it for 60 days.")
    }
    if currentCloudCopy != nil {
      return String(
        localized:
          "Delete Everywhere also moves its Google Photos copy to the Trash for 60 days. On this device it will be in Recently Deleted for 30 days."
      )
    }
    return isVideo
      ? String(
        localized:
          "This video will be deleted from the library, and from iCloud Photos if you use it. It will be in Recently Deleted for 30 days."
      )
      : String(
        localized:
          "This photo will be deleted from the library, and from iCloud Photos if you use it. It will be in Recently Deleted for 30 days."
      )
  }

  /// Delete asks first in a popover from the button, as in Photos (a dialog on the Mac).
  private func deleteButton(label: LocalizedStringKey) -> some View {
    circleButton("trash", label: label, role: .destructive) { askToDelete() }
      .keyboardShortcut(.delete, modifiers: .command)
      .onChange(of: deleteTarget) { confirmsDelete = false }
      .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: deleteTitleVisibility) {
        Button(deleteButtonTitle, role: .destructive) { deleteCurrent() }
        if currentCloudCopy != nil {
          Button("Delete from This Device", role: .destructive) { deleteCurrent(includingCopy: false) }
        }
      } message: {
        Text(deleteMessage)
      }
  }

  private var deleteTitleVisibility: Visibility {
    #if os(iOS)
      .hidden
    #else
      .visible
    #endif
  }

  // MARK: Chrome

  private func header(_ item: ViewerItem?) -> some View {
    HStack {
      circleButton("chevron.backward", label: "Back", action: close)
        .frame(minWidth: 72, alignment: .leading)
      Spacer()
      #if os(iOS)
        ScrubTitle(link: filmstrip, source: source, item: item) { ViewerTitle(item: $0, subtitle: subtitle(for:date:)) }
      #else
        ViewerTitle(item: item, subtitle: subtitle(for:date:))
      #endif
      Spacer()
      HStack(spacing: 8) {
        if isBusy {
          ProgressView().frame(width: 32, height: 32)
        } else if case .device(let asset, _) = item, asset.mediaSubtypes.contains(.photoLive) {
          circleButton(playingLive == asset.localIdentifier ? "livephoto.play" : "livephoto", label: "Play Live Photo") {
            playingLive = playingLive == asset.localIdentifier ? nil : asset.localIdentifier
          }
          #if os(iOS)
            .modifier(DisabledWhileScrubbing(link: filmstrip))
          #endif
        }
        if !isBusy {
          #if os(iOS)
            moreMenu(item).modifier(DisabledWhileScrubbing(link: filmstrip))
          #else
            moreMenu(item)
          #endif
        }
      }
      .frame(minWidth: 72, alignment: .trailing)
    }
    .padding(.horizontal, 20)
    #if os(macOS)
      // Clear of the window's toolbar above it.
      .padding(.top, 16)
    #endif
  }

  private func subtitle(for item: ViewerItem, date: Date) -> String {
    if case .cloud(let summary, _, let isOnDevice) = item {
      if let trashed = summary.trashedAt { return RemoteLibraryGridModel.daysLeft(trashedAt: trashed) }
      if !isOnDevice { return date.formatted(.dateTime.hour().minute()) + " · " + String(localized: "Google Photos") }
    }
    if case .file(let file, _, _) = item { return date.formatted(.dateTime.hour().minute()) + " · " + file.folderName }
    return date.formatted(.dateTime.hour().minute())
  }

  private func toolbar(_ item: ViewerItem?) -> some View {
    GlassEffectContainer {
      HStack(spacing: 12) {
        switch item {
        case .device(let asset, _): deviceButtons(asset)
        case .cloud(let item, let library, _): cloudButtons(item, library: library)
        case .file(let file, _, _): fileButtons(file)
        case nil: EmptyView()
        }
      }
    }
    .padding(.horizontal, 20)
    #if os(iOS)
      // On the tab bar's line, a little into the bottom safe area.
      .padding(.bottom, -7)
    #else
      // A window has no bottom safe area to reach into.
      .padding(.bottom, 12)
    #endif
  }

  @ViewBuilder private func deviceButtons(_ asset: PHAsset) -> some View {
    PhotoShareButton(
      items: [SharedAsset(asset)], identities: currentShareIdentity, videoCount: asset.mediaType == .video ? 1 : 0
    ) {
      Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 36, height: 36)
    }
    .accessibilityLabel("Share")
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    Spacer()
    actionGroup {
      favoriteButton(asset.isFavorite) { try await LibraryActions.toggleFavorite([asset]) }
      infoButton
    }
    Spacer()
    deleteButton(label: "Delete")
      .disabled(!asset.canPerform(.delete))
  }

  /// A folder file is shared or looked up here; it's removed from its folder by cleanup,
  /// after it's backed up, never from the viewer.
  @ViewBuilder private func fileButtons(_ file: FolderItemInfo) -> some View {
    PhotoShareButton(items: [FileSharedItem(item: file)], identities: currentShareIdentity, videoCount: file.isVideo ? 1 : 0) {
      Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 36, height: 36)
    }
    .accessibilityLabel("Share")
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    Spacer()
    actionGroup { infoButton }
    Spacer()
    // Keeps the info button in the middle, where it is for every other item.
    Color.clear.frame(width: 48, height: 48)
  }

  @ViewBuilder private func cloudButtons(_ item: RemoteItemSummary, library: CloudLibrary) -> some View {
    PhotoShareButton(
      items: [RemoteSharedItem(library: library, item: item)], identities: currentShareIdentity,
      videoCount: item.kind == .video ? 1 : 0
    ) {
      Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 36, height: 36)
    }
    .accessibilityLabel("Share")
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    Spacer()
    if item.trashedAt != nil {
      Button {
        run { try await library.restore([item]) }
      } label: {
        Label("Restore", systemImage: "arrow.uturn.backward").padding(.horizontal, 6)
      }
      .buttonStyle(.glass)
      infoButton
      Spacer()
      deleteButton(label: "Delete Forever")
    } else {
      actionGroup {
        favoriteButton(item.isFavorite) { try await library.toggleFavorite([item]) }
        infoButton
      }
      Spacer()
      deleteButton(label: "Move to Trash")
    }
  }

  /// The middle of the toolbar, as in Photos: icons sharing one piece of glass.
  private func actionGroup(@ViewBuilder _ content: () -> some View) -> some View {
    HStack(spacing: 6) { content() }
      .padding(.horizontal, 6)
      .frame(height: 48)
      .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func favoriteButton(_ isFavorite: Bool, action: @escaping @MainActor () async throws -> Void) -> some View {
    Button {
      if !isScrubbing { run(action) }
    } label: {
      Image(systemName: isFavorite ? "heart.fill" : "heart").font(.title3)
        .frame(width: 44, height: 44)
        .contentTransition(.symbolEffect(.replace))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .sensoryFeedback(.impact(weight: .light), trigger: isFavorite)
    .accessibilityLabel(Text(isFavorite ? "Unfavorite" : "Favorite"))
    .keyboardShortcut(".", modifiers: [])
  }

  private var infoButton: some View {
    Button {
      if !isScrubbing { showsInfo.toggle() }
    } label: {
      Image(systemName: showsInfo ? "info.circle.fill" : "info.circle").font(.title3)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Info")
    .keyboardShortcut("i", modifiers: .command)
  }

  /// Less frequent actions, behind "…" at the top right as in Photos.
  @ViewBuilder private var moreLabel: some View {
    #if os(macOS)
      Label("More", systemImage: "ellipsis.circle")
    #else
      Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 32, height: 32)
    #endif
  }

  @ViewBuilder private func moreMenu(_ current: ViewerItem?) -> some View {
    switch current {
    case .device(let asset, _):
      Menu {
        if asset.mediaType == .image {
          Button("Copy", systemImage: "doc.on.doc") { run { try await LibraryActions.copy(asset) } }
        }
        Button("Hide", systemImage: "eye.slash") { run { try await LibraryActions.setHidden([asset], hidden: true) } }
        if let copy = currentCloudCopy { moveToLockedFolderButton(copy.item, library: copy.library, keepsLocalCopy: true) }
      } label: {
        moreLabel
      }
      .moreMenuStyle()
    case .cloud(let item, let library, _) where item.trashedAt == nil:
      Menu {
        Button("Save to Device", systemImage: "arrow.down.circle") {
          run {
            let file = try await library.download(item)
            try await DeviceSaver.save([(file, item.kind == .video)])
          }
        }
        Button("Archive", systemImage: "archivebox") { run { try await library.setArchived([item], archived: true) } }
        moveToLockedFolderButton(item, library: library)
      } label: {
        moreLabel
      }
      .moreMenuStyle()
    case .file(_, _, let copy?) where copy.library.canMoveToLockedFolder(copy.item):
      Menu {
        moveToLockedFolderButton(copy.item, library: copy.library, keepsLocalCopy: true)
      } label: {
        moreLabel
      }
      .moreMenuStyle()
    default:
      EmptyView()
    }
  }

  @ViewBuilder private func moveToLockedFolderButton(
    _ item: RemoteItemSummary, library: CloudLibrary, keepsLocalCopy: Bool = false
  ) -> some View {
    if library.canMoveToLockedFolder(item) {
      Button(LockedFolderMove.title, systemImage: LockedFolderMove.symbol) {
        lockedFolderMove.request([item], in: library, keepsLocalCopies: keepsLocalCopy)
      }
      .disabled(lockedFolderMove.isMoving)
    }
  }

  #if os(macOS)
    private func macTitle(_ item: ViewerItem?) -> String {
      item?.date?.formatted(.dateTime.day().month(.wide).year()) ?? ""
    }

    private func macSubtitle(_ item: ViewerItem?) -> String {
      guard let current = item, let date = current.date else { return "" }
      return subtitle(for: current, date: date)
    }

    /// As in Photos on the Mac: back on the left, the item's actions on the right of the
    /// window's toolbar, with the usual shortcuts.
    @ToolbarContentBuilder private func macToolbar(_ viewerItem: ViewerItem?) -> some ToolbarContent {
      ToolbarItem(placement: .navigation) {
        Button("Back", systemImage: "chevron.backward", action: close)
          .help("Back to the grid (Esc)")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        // Always there, so the buttons beside it don't move as an action starts and ends.
        ProgressView().controlSize(.small).opacity(isBusy ? 1 : 0).accessibilityHidden(!isBusy)
        if case .device(let asset, _) = viewerItem, asset.mediaSubtypes.contains(.photoLive) {
          Button {
            playingLive = playingLive == asset.localIdentifier ? nil : asset.localIdentifier
          } label: {
            Label("Play Live Photo", systemImage: playingLive == asset.localIdentifier ? "livephoto.play" : "livephoto")
          }
          .help("Play Live Photo")
        }
        switch viewerItem {
        case .device(let asset, _):
          favoriteToolbarButton(asset.isFavorite) { try await LibraryActions.toggleFavorite([asset]) }
          infoToolbarButton
          PhotoShareButton(
            items: [SharedAsset(asset)], identities: currentShareIdentity, videoCount: asset.mediaType == .video ? 1 : 0
          ) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
          .help("Share")
          moreMenu(viewerItem)
          deleteToolbarButton.disabled(!asset.canPerform(.delete))
        case .cloud(let item, let library, _):
          if item.trashedAt != nil {
            Button {
              run { try await library.restore([item]) }
            } label: {
              Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .help("Restore from Trash")
            infoToolbarButton
            deleteToolbarButton
          } else {
            favoriteToolbarButton(item.isFavorite) { try await library.toggleFavorite([item]) }
            infoToolbarButton
            PhotoShareButton(
              items: [RemoteSharedItem(library: library, item: item)], identities: currentShareIdentity,
              videoCount: item.kind == .video ? 1 : 0
            ) {
              Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share")
            moreMenu(viewerItem)
            deleteToolbarButton
          }
        case .file(let file, _, _):
          infoToolbarButton
          PhotoShareButton(items: [FileSharedItem(item: file)], identities: currentShareIdentity, videoCount: file.isVideo ? 1 : 0) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
          .help("Share")
          moreMenu(viewerItem)
          Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            .help("Show in Finder")
        case nil:
          EmptyView()
        }
      }
    }

    private func favoriteToolbarButton(
      _ isFavorite: Bool, action: @escaping @MainActor () async throws -> Void
    ) -> some View {
      Button {
        run(action)
      } label: {
        Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
          .contentTransition(.symbolEffect(.replace))
      }
      .keyboardShortcut(".", modifiers: [])
      .help(isFavorite ? "Unfavorite (.)" : "Favorite (.)")
    }

    private var infoToolbarButton: some View {
      Button {
        showsInfo.toggle()
      } label: {
        Label("Info", systemImage: showsInfo ? "info.circle.fill" : "info.circle")
      }
      .keyboardShortcut("i", modifiers: .command)
      .help("Show Info (⌘I)")
    }

    private var deleteToolbarButton: some View {
      Button(role: .destructive) {
        askToDelete()
      } label: {
        Label(isTrashed ? "Delete Forever" : isCloud ? "Move to Trash" : "Delete", systemImage: "trash")
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .help(isTrashed ? "Delete Forever (⌘⌫)" : isCloud ? "Move to Trash (⌘⌫)" : "Delete (⌘⌫)")
    }
  #endif

  private func circleButton(
    _ symbol: String, label: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Image(systemName: symbol).font(.title3).frame(width: 36, height: 36)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .accessibilityLabel(Text(label))
  }

  /// What Delete would remove now: the item, and the Google Photos copy that goes with it.
  private var deleteTarget: String? {
    position.map { "\(source.itemID(at: $0))|\(source.cloudCopy(at: $0)?.item.mediaKey ?? "")" }
  }

  /// The strip is moving, so the open item isn't the one on screen (iPhone).
  private var isScrubbing: Bool {
    #if os(iOS)
      filmstrip.isMoving
    #else
      false
    #endif
  }

  private func askToDelete() {
    guard !isScrubbing else { return }
    deletingTarget = deleteTarget
    confirmsDelete = true
  }

  private func deleteCurrent(includingCopy: Bool = true) {
    guard let index = position else { return }
    let id = source.itemID(at: index)
    // The list can change under the open dialog: only what it asked about is deleted.
    guard deleteTarget == deletingTarget else { return }
    let removed = { removingID = id }
    switch current {
    case .device(let asset, _):
      let copy = includingCopy ? source.cloudCopy(at: index) : nil
      run {
        try await LibraryActions.delete([asset])
        if let copy { try await copy.library.trash([copy.item]) }
        removed()
      }
    case .cloud(let item, let library, _):
      run {
        if item.trashedAt != nil {
          try await library.deleteForever([item])
        } else {
          try await library.trash([item])
        }
        removed()
      }
    case .file, nil: break
    }
  }

  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
      isBusy = true
      defer { isBusy = false }
      do {
        try await action()
      } catch let error as PHPhotosError where error.code == .userCancelled {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  #if os(macOS)
    private func step(_ delta: Int) -> KeyPress.Result {
      guard let index = position else { return .ignored }
      let next = index + delta
      guard next >= 0, next < source.itemCount else { return .handled }
      withAnimation(reduceMotion ? nil : .smooth) { position = next }
      return .handled
    }
  #endif
}

extension View {
  /// A glass circle over the photo on iPhone; a plain toolbar menu on the Mac.
  @ViewBuilder fileprivate func moreMenuStyle() -> some View {
    #if os(macOS)
      self.help("More")
    #else
      self.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("More")
    #endif
  }
}

extension PhotoLibraryGridModel: MediaViewerSource {
  public func viewerItem(at index: Int) -> ViewerItem? {
    asset(at: index).map { .device($0, backup: backupState(at: index)) }
  }

  public func entityID(at index: Int) -> String? { asset(at: index)?.localIdentifier }
}

extension RemoteLibraryGridModel: MediaViewerSource {
  public func viewerItem(at index: Int) -> ViewerItem? {
    item(at: index).map { .cloud($0, library: library, isOnDevice: isOnDevice($0)) }
  }

  public func entityID(at index: Int) -> String? {
    item(at: index).map { LibraryIndexer.searchID(cloudMediaKey: $0.mediaKey) }
  }
}

private struct ViewerTitle: View {
  let item: ViewerItem?
  let subtitle: (ViewerItem, Date) -> String

  var body: some View {
    if let item, let date = item.date {
      VStack(spacing: 0) {
        Text(date, format: .dateTime.day().month().year()).font(.headline)
        Text(subtitle(item, date)).font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .glassEffect()
    }
  }
}

#if os(iOS)
  private struct DisabledWhileScrubbing: ViewModifier {
    let link: FilmstripLink

    func body(content: Content) -> some View {
      content.allowsHitTesting(!link.isMoving).accessibilityHidden(link.isMoving)
    }
  }

  /// Follows the filmstrip without the rest of the viewer.
  private struct ScrubTitle<Content: View>: View {
    let link: FilmstripLink
    let source: any MediaViewerSource
    let item: ViewerItem?
    @ViewBuilder let content: (ViewerItem?) -> Content

    var body: some View {
      let scrubbed = link.scrubbedIndex.flatMap {
        source.itemCount > $0 && !source.thumbnailIdentity(at: $0).isLocked ? source.viewerItem(at: $0) : nil
      }
      content(scrubbed ?? item)
    }
  }
#endif
