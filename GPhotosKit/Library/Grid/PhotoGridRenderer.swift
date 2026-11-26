import AppIntents
import CoreGraphics
import Foundation
import QuartzCore

/// What a grid shows. Items are addressed by index; ids key the image cache.
@MainActor
public protocol PhotoGridDataSource: AnyObject {
  var itemCount: Int { get }
  var thumbnailSource: any ThumbnailSource { get }
  var thumbnailRevision: Int { get }
  func itemID(at index: Int) -> String
  func thumbnailIdentity(at index: Int) -> ThumbnailIdentity
  func badges(at index: Int) -> PhotoGridBadges
  func accessibilityLabel(at index: Int) -> String
  /// Width over height of the full item, when known (grid thumbnails may be cropped).
  func aspectRatio(at index: Int) -> CGFloat?
  /// The item's `PhotoEntity` id, so Siri knows which photos are on screen.
  func entityID(at index: Int) -> String?
}

extension PhotoGridDataSource {
  public var thumbnailRevision: Int { 0 }
  public func thumbnailIdentity(at index: Int) -> ThumbnailIdentity { ThumbnailIdentity(id: itemID(at: index)) }
  public func aspectRatio(at index: Int) -> CGFloat? { nil }
  public func entityID(at index: Int) -> String? { nil }
}

public struct PhotoGridBadges: Equatable, Sendable {
  public enum Backup: Equatable, Sendable {
    case backedUp
    case pending
    case failed
    /// In Google Photos only, not on this device.
    case cloudOnly

    public var title: String {
      switch self {
      case .backedUp: String(localized: "Backed up")
      case .pending: String(localized: "Waiting to back up")
      case .failed: String(localized: "Backup failed")
      case .cloudOnly: String(localized: "In Google Photos only")
      }
    }
  }

  public var videoDuration: TimeInterval?
  public var isFavorite = false
  public var backup: Backup?

  public init(videoDuration: TimeInterval? = nil, isFavorite: Bool = false, backup: Backup? = nil) {
    self.videoDuration = videoDuration
    self.isFavorite = isFavorite
    self.backup = backup
  }
}

/// Draws a grid as one `CALayer` per visible cell, laid out by arithmetic and reused as
/// cells scroll away. No views, constraints or diffing per cell: a frame costs a few
/// layer property writes. Shared by the iOS and macOS hosts.
@MainActor
public final class PhotoGridRenderer {
  public let contentLayer = CALayer()
  public private(set) var layout: PhotoGridLayout
  public weak var dataSource: (any PhotoGridDataSource)? {
    didSet {
      if dataSource !== oldValue {
        stopCaching()
        thumbnailRevision = dataSource?.thumbnailRevision ?? 0
      }
    }
  }
  private var thumbnailRevision = 0
  public var displayScale: CGFloat = 2
  /// A cell left empty while its photo is drawn elsewhere (the zoom into the viewer). Set
  /// by position, kept by item, so a library change meanwhile hides the same photo.
  public var hiddenIndex: Int? {
    get { hiddenID.flatMap { id in visible.first { $0.value.itemID == id }?.key } }
    set {
      let id = newValue.flatMap { index in dataSource.map { $0.itemID(at: index) } }
      guard id != hiddenID else { return }
      hiddenID = id
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for cell in visible.values {
        let hides = id != nil && cell.itemID == id
        // Back from the viewer: the badges fade in over the photo that just landed.
        if cell.isHidden, !hides { cell.fadeInBadges(duration: 0.25) }
        cell.isHidden = hides
      }
      CATransaction.commit()
    }
  }
  private var hiddenID: String?
  public var selection: Set<Int> = [] {
    didSet { for (index, cell) in visible { applySelection(to: cell, at: index) } }
  }
  /// The item under the pointer (Mac), which shows the circle that selects it.
  public var hoveredIndex: Int? {
    didSet {
      guard hoveredIndex != oldValue else { return }
      for index in [oldValue, hoveredIndex].compactMap(\.self) {
        if let cell = visible[index] { applySelection(to: cell, at: index) }
      }
    }
  }
  /// While anything is selected on the Mac, every cell shows its circle, as on Google
  /// Photos for the web: a click then adds or removes an item instead of opening it.
  public var showsSelectionCircles = false {
    didSet {
      guard showsSelectionCircles != oldValue else { return }
      for (index, cell) in visible { applySelection(to: cell, at: index) }
    }
  }

  private func applySelection(to cell: PhotoGridCellLayer, at index: Int) {
    cell.isSelected = selection.contains(index)
    cell.showsSelectionCircle = showsSelectionCircles || hoveredIndex == index
  }

  private let pipeline: ThumbnailPipeline
  private var visible: [Int: PhotoGridCellLayer] = [:]
  private var pool: [PhotoGridCellLayer] = []
  private var cachingRange: Range<Int> = 0..<0
  private var warmed: [Int: ThumbnailCachingTarget] = [:]
  private var reconnectObserver: (any NSObjectProtocol)?
  private var warmCacheObserver: (any NSObjectProtocol)?
  private var lockObserver: (any NSObjectProtocol)?
  private var cachingBucket: ThumbnailBucket?
  /// Pre-decoding waits for a new layout to settle, so a pinch through several column
  /// counts only warms the one it ends on.
  private var cachingResume: Task<Void, Never>?
  private static let cachingSettle: Duration = .milliseconds(350)
  /// A dense grid holds hundreds of cells a screen; past this, only the nearest are warmed.
  private static let maxCached = 500
  private var lastRect: CGRect = .zero
  private var lastWanted: Range<Int>?
  private var layoutGlideUntil: CFTimeInterval = 0
  private var liveScale: (scale: CGFloat, point: CGPoint)?
  private var isZoomSettling = false
  /// Cells gliding off screen after a column change, reused once the glide ends.
  private var leaving: [Int: PhotoGridCellLayer] = [:]
  private var leavingCleanup: Task<Void, Never>?
  /// Cells of removed items shrinking away, dropped once they're gone.
  private var vanishing: [PhotoGridCellLayer] = []
  /// Between `detachCells()` and the reload that follows, nothing is laid out.
  private var isDetached = false
  static let glideDuration: TimeInterval = 0.36
  private var isScrollingFast = false
  /// The first screen of a grid is held back until its thumbnails are in (or a moment has
  /// passed), so it appears whole instead of as gray cells filling in one by one.
  private var isRevealPending = false
  private var revealGeneration = 0
  /// Whether the cells are drawn: false while they wait for their first images.
  public var isShowing: Bool { !isRevealPending }

  private var reportedPixels = false

  func hasPixels(in rect: CGRect) -> Bool {
    isShowing && visible.values.contains { !$0.isHidden && $0.contents != nil && $0.frame.intersects(rect) }
  }
  /// Every cell has its final image, not the small one that stands in for it.
  func hasAllPixels(in rect: CGRect) -> Bool {
    isShowing && !visible.isEmpty
      && !visible.values.contains {
        !$0.isHidden && $0.frame.intersects(rect) && $0.isWaiting
      }
  }
  /// Called when cells held back for their first images are drawn.
  public var onReveal: (() -> Void)?
  private var hasShownCells = false
  /// Drawn with the small images that stand in for them, cells would sharpen one by one.
  private static let revealTimeout: Duration = .milliseconds(250)

  public init(pipeline: ThumbnailPipeline = .shared) {
    self.pipeline = pipeline
    self.layout = PhotoGridLayout(columns: 4, width: 0, itemCount: 0)
    contentLayer.actions = PhotoGridCellLayer.noActions
    contentLayer.anchorPoint = .zero
    reconnectObserver = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didReconnect, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.retryVisibleMisses() }
    }
    warmCacheObserver = NotificationCenter.default.addObserver(
      forName: ThumbnailPipeline.didClearWarmCache, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopCaching() }
    }
    lockObserver = NotificationCenter.default.addObserver(
      forName: LockedItems.didLock, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.clearLockedCells() }
    }
  }

  isolated deinit {
    stopCaching()
    if let reconnectObserver { NotificationCenter.default.removeObserver(reconnectObserver) }
    if let warmCacheObserver { NotificationCenter.default.removeObserver(warmCacheObserver) }
    if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
  }

  /// Moved to the Locked Folder: gone from the screen at once, before the rows change.
  private func clearLockedCells() {
    for cell in Array(visible.values) + Array(leaving.values) + vanishing where cell.thumbnailIdentity?.isLocked == true {
      cell.cancelImageRequest()
      cell.contents = nil
      cell.isStale = false
    }
  }

  public var bucket: ThumbnailBucket { .forPixelSide(layout.itemSide * displayScale) }

  /// The pinch's scale about `point` (content coordinates), applied to the whole grid as
  /// one transform while the fingers move; nothing is laid out again until a column count
  /// is reached. Cells are filled in past the edges a scale below 1 reveals.
  public func setLiveScale(_ scale: CGFloat, about point: CGPoint, visibleRect: CGRect) {
    let beginsScale = liveScale == nil
    liveScale = (scale, point)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if beginsScale { contentLayer.removeAnimation(forKey: "transform") }
    contentLayer.transform = Self.transform(scale: scale, about: point)
    CATransaction.commit()
    update(visibleRect: visibleRect)
  }

  /// Springs back from a live scale that didn't reach another column count.
  public func endLiveScale(visibleRect: CGRect, animated: Bool) {
    guard liveScale != nil else { return }
    liveScale = nil
    let from = contentLayer.presentation()?.transform ?? contentLayer.transform
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.transform = CATransform3DIdentity
    if animated {
      let spring = Self.spring(keyPath: "transform")
      spring.fromValue = from
      contentLayer.add(spring, forKey: "transform")
    }
    CATransaction.commit()
    update(visibleRect: visibleRect, atRest: true)
  }

  /// Applies a new layout. With `animated`, every cell glides from where it is on screen
  /// to its new frame, cells coming into view glide in from where the old layout had them,
  /// and cells leaving glide out before they're reused, so pinching between column counts
  /// moves the whole grid as one. `shift` is how far the content offset moves with it.
  public func setLayout(
    _ newLayout: PhotoGridLayout, visibleRect: CGRect, animated: Bool = false, shift: CGFloat = 0,
    populate: Bool = true
  ) {
    let oldLayout = layout
    // Where the cells are on screen now (mid-animation, or under a live scale), in the new
    // content coordinates.
    let live = liveScale
    liveScale = nil
    let start = { (frame: CGRect) -> CGRect in
      let scaled = live.map { Self.rect(frame, scaledBy: $0.scale, about: $0.point) } ?? frame
      return scaled.offsetBy(dx: 0, dy: shift)
    }
    layout = newLayout
    lastWanted = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.bounds = CGRect(x: 0, y: 0, width: newLayout.width, height: newLayout.contentHeight)
    contentLayer.removeAnimation(forKey: "transform")
    contentLayer.transform = CATransform3DIdentity
    if animated, let dataSource, !visibleRect.isEmpty {
      let wanted = newLayout.indices(in: visibleRect.insetBy(dx: 0, dy: -newLayout.itemSide))
      isZoomSettling = true
      let now = CACurrentMediaTime()
      let isGliding = now < layoutGlideUntil
      layoutGlideUntil = now + Self.spring(keyPath: "position").duration
      // An exit gets one glide. A later pinch step can reclaim its bitmap if it comes back.
      for (index, cell) in leaving {
        if visible[index] == nil, wanted.contains(index) {
          visible[index] = cell
        } else {
          recycle(cell)
        }
      }
      leaving.removeAll(keepingCapacity: true)
      for (index, cell) in visible {
        guard index < newLayout.itemCount else {
          visible[index] = nil
          recycle(cell)
          continue
        }
        let from = start((isGliding ? cell.presentation()?.frame : nil) ?? cell.frame)
        Self.glide(cell, from: from, to: newLayout.frame(at: index))
        if !wanted.contains(index) {
          cell.cancelImageRequest()
          visible[index] = nil
          leaving[index] = cell
        }
      }
      for index in wanted {
        if let cell = visible[index] {
          if cell.contents == nil, cell.requestState == .missing {
            load(cell, at: index, dataSource: dataSource)
          }
          continue
        }
        let cell = addCell(at: index, dataSource: dataSource)
        Self.glide(cell, from: start(oldLayout.frame(at: index)), to: newLayout.frame(at: index))
      }
      lastWanted = wanted
      scheduleLeavingCleanup()
    } else if populate {
      for (index, cell) in visible where index < newLayout.itemCount {
        cell.removeAllAnimations()
        cell.removeBadgeAnimations()
        cell.frame = newLayout.frame(at: index)
      }
      refreshImages()
    }
    CATransaction.commit()
    stopCaching()
    cachingResume?.cancel()
    cachingResume = Task { [weak self] in
      try? await Task.sleep(for: Self.cachingSettle)
      guard !Task.isCancelled, let self else { return }
      self.cachingResume = nil
      if self.isZoomSettling {
        self.isZoomSettling = false
        self.refreshImages()
      }
      if let dataSource = self.dataSource, !self.lastRect.isEmpty, !self.isScrollingFast, self.liveScale == nil {
        self.updateCaching(around: self.lastRect, velocity: 0, dataSource: dataSource)
      }
    }
    if populate { update(visibleRect: visibleRect) }
  }

  /// Everything changed (new library contents): every cell is rebuilt.
  public func reloadData(visibleRect: CGRect) {
    isDetached = false
    lastWanted = nil
    for cell in visible.values { recycle(cell) }
    visible.removeAll(keepingCapacity: true)
    clearExitingCells()
    stopCaching()
    update(visibleRect: visibleRect)
  }

  /// The cells on screen, keyed by their item, taken off the grid before its contents
  /// change; pass them to `reloadData(visibleRect:previous:shift:)`. Until then the grid
  /// draws nothing new.
  func detachCells() -> [String: PhotoGridCellLayer] {
    var cells: [String: PhotoGridCellLayer] = [:]
    for (_, cell) in visible {
      if let id = cell.itemID, cells[id] == nil {
        // Where it is on screen now, even mid-glide.
        let frame = cell.presentation()?.frame ?? cell.frame
        cell.removeAllAnimations()
        cell.removeBadgeAnimations()
        cell.frame = frame
        cells[id] = cell
      } else {
        recycle(cell)
      }
    }
    visible.removeAll(keepingCapacity: true)
    lastWanted = nil
    clearExitingCells()
    stopCaching()
    isDetached = true
    return cells
  }

  /// New contents with the cells taken by `detachCells()`: an item still on screen glides
  /// from where it was to its new place, one that's new grows in, and one that's gone
  /// shrinks away, as in Photos. `shift` is how far the content offset moved meanwhile.
  /// When most of what's on screen changed (another filter or account), it's a plain
  /// reload instead.
  func reloadData(visibleRect: CGRect, previous: [String: PhotoGridCellLayer], shift: CGFloat, animated: Bool = true) {
    isDetached = false
    guard let dataSource, !visibleRect.isEmpty, !previous.isEmpty else {
      for (_, cell) in previous { recycle(cell) }
      return reloadData(visibleRect: visibleRect)
    }
    var previous = previous
    let wanted = layout.indices(in: visibleRect.insetBy(dx: 0, dy: -layout.itemSide))
      .clamped(to: 0..<dataSource.itemCount)
    let identities = wanted.map { dataSource.thumbnailIdentity(at: $0) }
    guard identities.count(where: { previous[$0.id] != nil }) * 2 >= min(identities.count, previous.count) else {
      for (_, cell) in previous { recycle(cell) }
      return reloadData(visibleRect: visibleRect)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, identity) in zip(wanted, identities) {
      let id = identity.id
      let to = layout.frame(at: index)
      if let cell = previous.removeValue(forKey: id) {
        if animated { Self.glide(cell, from: cell.frame.offsetBy(dx: 0, dy: shift), to: to) } else { cell.frame = to }
        cell.isHidden = hiddenID == id
        applySelection(to: cell, at: index)
        cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
        visible[index] = cell
        if cell.requestedBucket != bucket || cell.thumbnailIdentity != identity || identity.isLocked {
          cell.cancelImageRequest()
          load(cell, at: index, dataSource: dataSource, identity: identity)
        }
      } else {
        let cell = dequeue()
        cell.frame = to
        applySelection(to: cell, at: index)
        cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
        visible[index] = cell
        load(cell, at: index, dataSource: dataSource, identity: identity)
        cell.isHidden = hiddenID == id
        if animated { Self.pop(cell, appearing: true) }
      }
    }
    for (_, cell) in previous {
      if animated, cell.thumbnailIdentity?.isLocked != true {
        cell.cancelImageRequest()
        cell.frame = cell.frame.offsetBy(dx: 0, dy: shift)
        Self.pop(cell, appearing: false)
        vanishing.append(cell)
      } else {
        recycle(cell)
      }
    }
    CATransaction.commit()
    lastWanted = wanted
    layoutGlideUntil = CACurrentMediaTime() + Self.spring(keyPath: "position").duration
    scheduleLeavingCleanup()
    update(visibleRect: visibleRect)
  }

  private func holdUntilImagesArrive() {
    guard visible.values.contains(where: \.isWaiting) else { return }
    isRevealPending = true
    revealGeneration &+= 1
    let generation = revealGeneration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.opacity = 0
    CATransaction.commit()
    Task { [weak self] in
      try? await Task.sleep(for: Self.revealTimeout)
      // A later hold has its own timeout.
      guard let self, generation == self.revealGeneration else { return }
      self.reveal()
    }
  }

  private func reportImageArrival() {
    let wasShowing = isShowing
    revealIfReady()
    if !reportedPixels, hasPixels(in: lastRect) {
      reportedPixels = true
      if wasShowing { onReveal?() }
    }
  }

  private func revealIfReady() {
    guard isRevealPending, !visible.values.contains(where: \.isWaiting) else { return }
    reveal()
  }

  private func reveal() {
    guard isRevealPending else { return }
    isRevealPending = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.opacity = 1
    CATransaction.commit()
    onReveal?()
  }

  /// Lays out the cells for `visibleRect` (in content coordinates). `velocity` is in
  /// points per second; above about three screens a second images load only from cache
  /// and PhotoKit's fast format, and full thumbnails follow once scrolling slows.
  public func update(visibleRect: CGRect, velocity: CGFloat = 0, atRest: Bool = false) {
    guard let dataSource, !isDetached else { return }
    guard !visibleRect.isEmpty, layout.width > 0 else {
      lastRect = .zero
      stopCaching()
      return
    }
    let visibleRect = liveScale.map { Self.rect(visibleRect, unscaledBy: $0.scale, about: $0.point) } ?? visibleRect
    lastRect = visibleRect
    // Near the cutoff, frame-time jitter should not start and stop sharp requests each row.
    let fast = abs(velocity) > max(visibleRect.height, 1) * (isScrollingFast ? 2 : 3)
    let settled = isScrollingFast && !fast
    isScrollingFast = fast

    let wanted = layout.indices(in: visibleRect.insetBy(dx: 0, dy: -layout.itemSide))
      .clamped(to: 0..<dataSource.itemCount)
    if wanted != lastWanted {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if let lastWanted {
        for removed in Self.subtract(lastWanted, wanted) {
          for index in removed {
            if let cell = visible.removeValue(forKey: index) { recycle(cell) }
          }
        }
        for added in Self.subtract(wanted, lastWanted) {
          for index in added { _ = addCell(at: index, dataSource: dataSource) }
        }
      } else {
        for (index, cell) in visible where !wanted.contains(index) {
          visible[index] = nil
          recycle(cell)
        }
        for index in wanted where visible[index] == nil { _ = addCell(at: index, dataSource: dataSource) }
      }
      CATransaction.commit()
      lastWanted = wanted
    }
    // An emptied grid (another account, a filter) holds its next first screen too.
    if dataSource.itemCount == 0 {
      reportedPixels = false
      hasShownCells = false
    }
    if !hasShownCells, !visible.isEmpty {
      hasShownCells = true
      holdUntilImagesArrive()
    }
    reportImageArrival()
    if settled || atRest, !isZoomSettling, liveScale == nil { refreshImages() }
    if !fast, cachingResume == nil, liveScale == nil { updateCaching(around: visibleRect, velocity: velocity, dataSource: dataSource) }
  }

  public func index(at point: CGPoint) -> Int? { layout.index(at: point) }

  public var visibleIndices: [Int] { visible.keys.sorted() }

  /// The items Siri asks for, as it sees them: where each is (in content coordinates) and
  /// whether it's selected. Siri asks for what's in a rect, the selection (also scrolled
  /// out of view: "share these"), or both; without a request, what's in `visible`.
  public func siriElements(_ context: AppEntityUIElementsContext, visible: CGRect) -> [AppEntityUIElement] {
    guard let dataSource else { return [] }
    var indices = Set<Int>()
    for request in context.requests {
      switch request {
      case .visible(let rect): indices.formUnion(layout.indices(in: rect))
      case .selected: indices.formUnion(selection)
      @unknown default: indices.formUnion(layout.indices(in: visible))
      }
    }
    if context.requests.isEmpty { indices.formUnion(layout.indices(in: visible)) }
    return indices.filter { $0 < dataSource.itemCount }.sorted().compactMap { index in
      guard let id = dataSource.entityID(at: index) else { return nil }
      return AppEntityUIElement(
        identifier: EntityIdentifier(for: PhotoEntity.self, identifier: id),
        bounds: layout.frame(at: index),
        state: .init(isSelected: selection.contains(index)))
    }
  }

  // A lock can arrive before the merged rows, or while a removed cell is animating out.
  func hasLockedPixels(in rect: CGRect) -> Bool {
    func isLocked(_ cell: PhotoGridCellLayer) -> Bool {
      cell.contents != nil && cell.frame.intersects(rect) && cell.thumbnailIdentity?.isLocked == true
    }
    return visible.values.contains(where: isLocked) || leaving.values.contains(where: isLocked)
      || vanishing.contains(where: isLocked)
  }

  /// The layer drawing `index`, while it's on screen (for context menu previews).
  public func cellLayer(at index: Int) -> CALayer? { visible[index] }

  /// The first item whose row is at or below `y`, for the date label while scrolling.
  public func topIndex(atY y: CGFloat) -> Int? {
    guard layout.itemCount > 0 else { return nil }
    let range = layout.indices(in: CGRect(x: 0, y: max(0, y), width: max(layout.width, 1), height: 1))
    return range.isEmpty ? (y <= 0 ? 0 : layout.itemCount - 1) : range.lowerBound
  }

  /// Indices of cells that intersect `rect`, for rubber-band selection.
  public func indices(intersecting rect: CGRect) -> [Int] {
    layout.indices(in: rect).filter { layout.frame(at: $0).intersects(rect) }
  }

  func refreshThumbnailSourceIfNeeded(visibleRect: CGRect) {
    guard let dataSource, dataSource.thumbnailRevision != thumbnailRevision else { return }
    thumbnailRevision = dataSource.thumbnailRevision
    refreshImages(checkIdentities: true)
    updateCaching(around: visibleRect, velocity: 0, dataSource: dataSource, refreshTargets: true)
  }

  public func refreshBadges() {
    guard let dataSource else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, cell) in visible where index < dataSource.itemCount {
      cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
    }
    CATransaction.commit()
  }

  public func tearDown() {
    for (_, cell) in visible { recycle(cell) }
    visible.removeAll()
    lastWanted = nil
    clearExitingCells()
    cachingResume?.cancel()
    cachingResume = nil
    stopCaching()
  }

  private func addCell(at index: Int, dataSource: any PhotoGridDataSource) -> PhotoGridCellLayer {
    if let cell = leaving.removeValue(forKey: index) {
      cell.removeAllAnimations()
      cell.removeBadgeAnimations()
      cell.frame = layout.frame(at: index)
      visible[index] = cell
      applySelection(to: cell, at: index)
      if cell.requestState == .missing || cell.requestedBucket != bucket {
        load(cell, at: index, dataSource: dataSource)
      }
      return cell
    }
    let cell = dequeue()
    cell.frame = layout.frame(at: index)
    applySelection(to: cell, at: index)
    cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
    visible[index] = cell
    load(cell, at: index, dataSource: dataSource)
    cell.isHidden = hiddenID != nil && cell.itemID == hiddenID
    return cell
  }

  private func load(
    _ cell: PhotoGridCellLayer, at index: Int, dataSource: any PhotoGridDataSource, identity: ThumbnailIdentity? = nil
  ) {
    let identity = identity ?? dataSource.thumbnailIdentity(at: index)
    // The same item's newer pixels replace the old ones once they're here.
    let keepsPixels =
      cell.contents != nil && !identity.isLocked && cell.thumbnailIdentity?.isLocked == false
      && cell.thumbnailIdentity?.id == identity.id && cell.thumbnailIdentity?.accountEmail == identity.accountEmail
    if keepsPixels {
      if cell.thumbnailIdentity != identity { cell.isStale = true }
    } else if cell.thumbnailIdentity != identity || identity.isLocked {
      cell.contents = nil
      cell.isStale = false
    }
    cell.thumbnailIdentity = identity
    let key = ThumbnailKey(identity: identity, bucket: bucket)
    cell.itemID = key.id
    cell.requestedBucket = key.bucket
    if let image = pipeline.cachedImage(for: key) {
      cell.setImage(image)
      cell.requestQuality = .thumbnail
      cell.requestState = .ready
      reportImageArrival()
      return
    }
    if cell.contents == nil, let image = pipeline.placeholder(for: key) { cell.setImage(image) }

    let quick = isScrollingFast || isZoomSettling || liveScale != nil
    let quality: ImageRequestQuality = quick ? .fast : .thumbnail
    let requestKey = quick ? ThumbnailKey(identity: identity, bucket: .tiny) : key
    cell.requestQuality = quality
    cell.requestState = .pending
    let ticket = pipeline.load(
      requestKey, from: dataSource.thumbnailSource, quality: quality,
      onUnavailable: { [weak self, weak cell] in
        cell?.requestState = .missing
        cell?.ticket = nil
        self?.reportImageArrival()
        if let cell, cell.isStale, cell.thumbnailIdentity == identity {
          cell.contents = nil
          cell.isStale = false
        }
      },
      handler: { [weak self, weak cell] image, isFinal in
        guard let cell, cell.thumbnailIdentity == identity else { return }
        if (isFinal && (!quick || cell.isStale)) || cell.contents == nil {
          cell.setImage(image)
          self?.reportImageArrival()
        }
        if isFinal {
          cell.requestState = .ready
          cell.ticket = nil
          self?.reportImageArrival()
        }
      })
    if cell.requestState == .pending { cell.ticket = ticket }
  }

  /// Reuse matching work and keep the pixels on screen while a new bucket loads.
  private func refreshImages(checkIdentities: Bool = false) {
    guard let dataSource else { return }
    let bucket = self.bucket
    let quick = isScrollingFast || isZoomSettling || liveScale != nil
    for (index, cell) in visible where index < dataSource.itemCount {
      let identity = checkIdentities ? dataSource.thumbnailIdentity(at: index) : cell.thumbnailIdentity
      guard
        cell.thumbnailIdentity != identity || cell.requestState == .missing || cell.requestedBucket != bucket
          || (!quick && cell.requestQuality == .fast)
      else { continue }
      cell.cancelImageRequest()
      load(cell, at: index, dataSource: dataSource, identity: checkIdentities ? identity : nil)
    }
  }

  private func retryVisibleMisses() {
    guard !isDetached, !isScrollingFast, !isZoomSettling, liveScale == nil, let dataSource else { return }
    for (index, cell) in visible where index < dataSource.itemCount && cell.requestState == .missing {
      load(cell, at: index, dataSource: dataSource)
    }
  }

  private func clearExitingCells() {
    leavingCleanup?.cancel()
    leavingCleanup = nil
    for cell in leaving.values { recycle(cell) }
    leaving.removeAll(keepingCapacity: true)
    for cell in vanishing { recycle(cell) }
    vanishing.removeAll(keepingCapacity: true)
  }

  private func scheduleLeavingCleanup() {
    leavingCleanup?.cancel()
    guard !leaving.isEmpty || !vanishing.isEmpty else { return }
    leavingCleanup = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.spring(keyPath: "position").duration))
      guard !Task.isCancelled, let self else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.clearExitingCells()
      CATransaction.commit()
    }
  }

  /// Core Animation copies the configured spring when it is added to a layer.
  private static let springs: [String: CASpringAnimation] = Dictionary(
    uniqueKeysWithValues: ["position", "bounds.size", "opacity", "transform"].map { keyPath in
      let spring = CASpringAnimation(perceptualDuration: glideDuration, bounce: 0)
      spring.keyPath = keyPath
      spring.duration = spring.settlingDuration
      return (keyPath, spring)
    })

  private static func spring(keyPath: String) -> CASpringAnimation { springs[keyPath]! }

  /// Sets `to` as the cell's frame and animates there from `from`. Cells are anchored at
  /// their origin, so position and size animate independently.
  private static func glide(_ cell: PhotoGridCellLayer, from: CGRect, to: CGRect) {
    cell.frame = to
    guard from != to else {
      cell.removeAllAnimations()
      return
    }
    let position = spring(keyPath: "position")
    position.fromValue = from.origin
    cell.add(position, forKey: "position")
    guard from.size != to.size else { return }
    let size = spring(keyPath: "bounds.size")
    size.fromValue = from.size
    cell.add(size, forKey: "bounds.size")
    cell.animateBadges(fromSide: from.width) { spring(keyPath: $0) }
  }

  /// An item growing in from the middle of its cell, or shrinking away into it.
  private static func pop(_ cell: PhotoGridCellLayer, appearing: Bool) {
    let center = CGPoint(x: cell.bounds.midX, y: cell.bounds.midY)
    let small = transform(scale: 0.6, about: center)
    let transform = spring(keyPath: "transform")
    transform.fromValue = appearing ? small : CATransform3DIdentity
    let opacity = spring(keyPath: "opacity")
    opacity.fromValue = appearing ? 0 : 1
    cell.transform = appearing ? CATransform3DIdentity : small
    cell.opacity = appearing ? 1 : 0
    cell.add(transform, forKey: "transform")
    cell.add(opacity, forKey: "opacity")
  }

  nonisolated static func transform(scale: CGFloat, about point: CGPoint) -> CATransform3D {
    CATransform3DConcat(
      CATransform3DMakeScale(scale, scale, 1),
      CATransform3DMakeTranslation(point.x * (1 - scale), point.y * (1 - scale), 0))
  }

  nonisolated static func rect(_ rect: CGRect, scaledBy scale: CGFloat, about point: CGPoint) -> CGRect {
    CGRect(
      x: point.x + (rect.minX - point.x) * scale, y: point.y + (rect.minY - point.y) * scale,
      width: rect.width * scale, height: rect.height * scale)
  }

  /// The content a scaled grid shows in `rect`.
  nonisolated static func rect(_ rect: CGRect, unscaledBy scale: CGFloat, about point: CGPoint) -> CGRect {
    self.rect(rect, scaledBy: 1 / max(scale, 0.01), about: point)
  }

  private func dequeue() -> PhotoGridCellLayer {
    let cell = pool.popLast() ?? PhotoGridCellLayer()
    cell.isHidden = false
    if cell.superlayer == nil { contentLayer.addSublayer(cell) }
    return cell
  }

  private func recycle(_ cell: PhotoGridCellLayer) {
    cell.removeAllAnimations()
    cell.removeBadgeAnimations()
    cell.transform = CATransform3DIdentity
    cell.opacity = 1
    cell.prepareForReuse()
    cell.isHidden = true
    // Spare layers absorb row churn and the cells a pinch to more columns needs (they hold
    // no image); the rest are dropped.
    if pool.count < 320 {
      pool.append(cell)
    } else {
      cell.removeFromSuperlayer()
    }
  }

  /// PhotoKit pre-decodes a window two screens ahead in the scroll direction and half a
  /// screen behind; only the cells entering or leaving the window are sent.
  private func updateCaching(
    around rect: CGRect, velocity: CGFloat, dataSource: any PhotoGridDataSource, refreshTargets: Bool = false
  ) {
    let ahead = rect.height * 2
    let behind = rect.height * 0.5
    let window =
      velocity >= 0
      ? CGRect(x: rect.minX, y: rect.minY - behind, width: rect.width, height: rect.height + ahead + behind)
      : CGRect(x: rect.minX, y: rect.minY - ahead, width: rect.width, height: rect.height + ahead + behind)
    var range = layout.indices(in: window)
    if range.count > Self.maxCached {
      let shown = layout.indices(in: rect)
      let count = max(Self.maxCached, shown.count)
      range =
        velocity >= 0
        ? shown.lowerBound..<min(range.upperBound, shown.lowerBound + count)
        : max(range.lowerBound, shown.upperBound - count)..<shown.upperBound
    }
    let bucket = self.bucket
    if cachingBucket != bucket {
      stopCaching()
      cachingBucket = bucket
    }
    guard refreshTargets || range != cachingRange else { return }
    let source = dataSource.thumbnailSource
    var removed: [ThumbnailCachingTarget] = []
    for indices in Self.subtract(cachingRange, range) {
      for index in indices {
        if let target = warmed.removeValue(forKey: index) { removed.append(target) }
      }
    }
    var added: [ThumbnailCachingTarget] = []
    let toCheck = refreshTargets ? [range] : Self.subtract(range, cachingRange)
    for indices in toCheck {
      for index in indices.clamped(to: 0..<dataSource.itemCount) {
        let previous = warmed[index]
        let target = source.cachingTarget(for: dataSource.itemID(at: index))
        if previous?.id == target?.id,
          previous.map({ ObjectIdentifier($0.source) }) == target.map({ ObjectIdentifier($0.source) })
        {
          continue
        }
        if let previous { removed.append(previous) }
        if let target { added.append(target) }
        warmed[index] = target
      }
    }
    cachingRange = range
    for group in Self.grouped(removed) {
      group.source.stopCaching(ids: group.ids, pixelSize: bucket.pixelSize)
    }
    for group in Self.grouped(added) {
      group.source.startCaching(ids: group.ids, pixelSize: bucket.pixelSize)
    }
  }

  private func stopCaching() {
    if let cachingBucket {
      for group in Self.grouped(warmed.values) {
        group.source.stopCaching(ids: group.ids, pixelSize: cachingBucket.pixelSize)
      }
    }
    warmed.removeAll(keepingCapacity: true)
    cachingRange = 0..<0
    cachingBucket = nil
  }

  private static func grouped(_ work: some Sequence<ThumbnailCachingTarget>) -> [(source: any ThumbnailSource, ids: [String])] {
    var grouped: [ObjectIdentifier: (source: any ThumbnailSource, ids: [String])] = [:]
    for target in work {
      grouped[ObjectIdentifier(target.source), default: (target.source, [])].ids.append(target.id)
    }
    return Array(grouped.values)
  }

  nonisolated static func subtract(_ lhs: Range<Int>, _ rhs: Range<Int>) -> [Range<Int>] {
    guard !lhs.isEmpty else { return [] }
    guard !rhs.isEmpty, lhs.overlaps(rhs) else { return [lhs] }
    var result: [Range<Int>] = []
    if lhs.lowerBound < rhs.lowerBound { result.append(lhs.lowerBound..<rhs.lowerBound) }
    if rhs.upperBound < lhs.upperBound { result.append(rhs.upperBound..<lhs.upperBound) }
    return result
  }
}
