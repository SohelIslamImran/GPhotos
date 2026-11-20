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
  func badges(at index: Int) -> PhotoGridBadges
  func accessibilityLabel(at index: Int) -> String
  /// Width over height of the full item, when known (grid thumbnails may be cropped).
  func aspectRatio(at index: Int) -> CGFloat?
  /// The item's `PhotoEntity` id, so Siri knows which photos are on screen.
  func entityID(at index: Int) -> String?
}

extension PhotoGridDataSource {
  public var thumbnailRevision: Int { 0 }
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
      if dataSource !== oldValue { thumbnailRevision = dataSource?.thumbnailRevision ?? 0 }
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
  private var cachingBucket: ThumbnailBucket?
  /// Pre-decoding waits for a new layout to settle, so a pinch through several column
  /// counts only warms the one it ends on.
  private var cachingResume: Task<Void, Never>?
  private static let cachingSettle: Duration = .milliseconds(350)
  /// A dense grid holds hundreds of cells a screen; past this, only the nearest are warmed.
  private static let maxCached = 500
  private var lastRect: CGRect = .zero
  private var liveScale: (scale: CGFloat, point: CGPoint)?
  /// Cells kept their larger images through a pinch to smaller ones.
  private var needsRefreshWhenSettled = false
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
  /// Called when cells held back for their first images are drawn.
  public var onReveal: (() -> Void)?
  private var hasShownCells = false
  private static let revealTimeout: Duration = .milliseconds(300)

  public init(pipeline: ThumbnailPipeline = .shared) {
    self.pipeline = pipeline
    self.layout = PhotoGridLayout(columns: 4, width: 0, itemCount: 0)
    contentLayer.actions = PhotoGridCellLayer.noActions
    contentLayer.anchorPoint = .zero
  }

  public var bucket: ThumbnailBucket { .forPixelSide(layout.itemSide * displayScale) }

  /// The pinch's scale about `point` (content coordinates), applied to the whole grid as
  /// one transform while the fingers move; nothing is laid out again until a column count
  /// is reached. Cells are filled in past the edges a scale below 1 reveals.
  public func setLiveScale(_ scale: CGFloat, about point: CGPoint, visibleRect: CGRect) {
    liveScale = (scale, point)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.removeAnimation(forKey: "transform")
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
    update(visibleRect: visibleRect)
  }

  /// Applies a new layout. With `animated`, every cell glides from where it is on screen
  /// to its new frame, cells coming into view glide in from where the old layout had them,
  /// and cells leaving glide out before they're reused, so pinching between column counts
  /// moves the whole grid as one. `shift` is how far the content offset moves with it.
  public func setLayout(
    _ newLayout: PhotoGridLayout, visibleRect: CGRect, animated: Bool = false, shift: CGFloat = 0
  ) {
    let oldBucket = bucket
    let newBucket = ThumbnailBucket.forPixelSide(newLayout.itemSide * displayScale)
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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.bounds = CGRect(x: 0, y: 0, width: newLayout.width, height: newLayout.contentHeight)
    contentLayer.removeAnimation(forKey: "transform")
    contentLayer.transform = CATransform3DIdentity
    if animated, let dataSource {
      let wanted = newLayout.indices(in: visibleRect.insetBy(dx: 0, dy: -newLayout.itemSide))
      // Cells still gliding out of the last change can be the ones wanted now.
      for (index, cell) in leaving where visible[index] == nil && wanted.contains(index) {
        visible[index] = cell
        leaving[index] = nil
      }
      var moves: [(PhotoGridCellLayer, CGRect, CGRect)] = []
      for (index, cell) in leaving where index < newLayout.itemCount {
        moves.append((cell, start(cell.presentation()?.frame ?? cell.frame), newLayout.frame(at: index)))
      }
      for (index, cell) in visible {
        guard index < newLayout.itemCount else { continue }
        moves.append((cell, start(cell.presentation()?.frame ?? cell.frame), newLayout.frame(at: index)))
        if !wanted.contains(index) {
          visible[index] = nil
          leaving[index] = cell
        }
      }
      // Cells already on screen ask for sharper images only when they grow; shrinking,
      // what they show is sharp enough until the pinch settles.
      if newBucket > oldBucket { refreshImages() }
      for index in wanted where visible[index] == nil {
        let cell = dequeue()
        applySelection(to: cell, at: index)
        cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
        visible[index] = cell
        load(cell, at: index, dataSource: dataSource)
        moves.append((cell, start(oldLayout.frame(at: index)), newLayout.frame(at: index)))
      }
      for (cell, from, to) in moves { Self.glide(cell, from: from, to: to) }
      scheduleLeavingCleanup()
      if newBucket < oldBucket { needsRefreshWhenSettled = true }
    } else {
      for (index, cell) in visible where index < newLayout.itemCount {
        cell.removeAllAnimations()
        cell.removeBadgeAnimations()
        cell.frame = newLayout.frame(at: index)
      }
      if newBucket != oldBucket { refreshImages() }
    }
    CATransaction.commit()
    stopCaching()
    cachingResume?.cancel()
    cachingResume = Task { [weak self] in
      try? await Task.sleep(for: Self.cachingSettle)
      guard !Task.isCancelled, let self else { return }
      self.cachingResume = nil
      if self.needsRefreshWhenSettled {
        self.needsRefreshWhenSettled = false
        self.refreshImages()
      }
      if let dataSource = self.dataSource {
        self.updateCaching(around: self.lastRect, velocity: 0, dataSource: dataSource)
      }
    }
    update(visibleRect: visibleRect)
  }

  /// Everything changed (new library contents): every cell is rebuilt.
  public func reloadData(visibleRect: CGRect) {
    for (_, cell) in visible { recycle(cell) }
    visible.removeAll()
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
    visible.removeAll()
    for (_, cell) in leaving { recycle(cell) }
    leaving.removeAll()
    isDetached = true
    return cells
  }

  /// New contents with the cells taken by `detachCells()`: an item still on screen glides
  /// from where it was to its new place, one that's new grows in, and one that's gone
  /// shrinks away, as in Photos. `shift` is how far the content offset moved meanwhile.
  /// When most of what's on screen changed (another filter or account), it's a plain
  /// reload instead.
  func reloadData(visibleRect: CGRect, previous: [String: PhotoGridCellLayer], shift: CGFloat) {
    isDetached = false
    guard let dataSource, !previous.isEmpty else {
      for (_, cell) in previous { recycle(cell) }
      return reloadData(visibleRect: visibleRect)
    }
    var previous = previous
    let wanted = layout.indices(in: visibleRect.insetBy(dx: 0, dy: -layout.itemSide))
    let ids = wanted.map { dataSource.itemID(at: $0) }
    guard ids.count(where: { previous[$0] != nil }) * 2 >= min(ids.count, previous.count) else {
      for (_, cell) in previous { recycle(cell) }
      return reloadData(visibleRect: visibleRect)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, id) in zip(wanted, ids) {
      let to = layout.frame(at: index)
      if let cell = previous.removeValue(forKey: id) {
        Self.glide(cell, from: cell.frame.offsetBy(dx: 0, dy: shift), to: to)
        cell.isHidden = hiddenID == id
        applySelection(to: cell, at: index)
        cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
        visible[index] = cell
      } else {
        let cell = dequeue()
        cell.frame = to
        applySelection(to: cell, at: index)
        cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
        visible[index] = cell
        load(cell, at: index, dataSource: dataSource)
        cell.isHidden = hiddenID == id
        Self.pop(cell, appearing: true)
      }
    }
    for (_, cell) in previous {
      cell.frame = cell.frame.offsetBy(dx: 0, dy: shift)
      Self.pop(cell, appearing: false)
      vanishing.append(cell)
    }
    CATransaction.commit()
    scheduleLeavingCleanup()
    stopCaching()
    update(visibleRect: visibleRect)
  }

  private func holdUntilImagesArrive() {
    guard visible.values.contains(where: { $0.contents == nil }) else { return }
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

  private func revealIfReady() {
    guard isRevealPending, !visible.values.contains(where: { $0.contents == nil }) else { return }
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
  public func update(visibleRect: CGRect, velocity: CGFloat = 0) {
    guard let dataSource, !isDetached else { return }
    let visibleRect = liveScale.map { Self.rect(visibleRect, unscaledBy: $0.scale, about: $0.point) } ?? visibleRect
    lastRect = visibleRect
    let fast = abs(velocity) > max(visibleRect.height, 1) * 3
    let settled = isScrollingFast && !fast
    isScrollingFast = fast

    let wanted = layout.indices(in: visibleRect.insetBy(dx: 0, dy: -layout.itemSide))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, cell) in visible where !wanted.contains(index) || index >= dataSource.itemCount {
      visible[index] = nil
      recycle(cell)
    }
    for index in wanted where visible[index] == nil {
      let cell = dequeue()
      cell.frame = layout.frame(at: index)
      applySelection(to: cell, at: index)
      cell.apply(badges: dataSource.badges(at: index), scale: displayScale)
      visible[index] = cell
      load(cell, at: index, dataSource: dataSource)
      cell.isHidden = hiddenID != nil && cell.itemID == hiddenID
    }
    CATransaction.commit()
    // An emptied grid (another account, a filter) holds its next first screen too.
    if dataSource.itemCount == 0 { hasShownCells = false }
    if !hasShownCells, !visible.isEmpty {
      hasShownCells = true
      holdUntilImagesArrive()
    }
    // Images straight from the cache arrive during the pass; a held grid shows once every
    // cell in it has one.
    revealIfReady()
    if settled { refreshImages() }
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
    stopCaching()
    refreshImages()
    updateCaching(around: visibleRect, velocity: 0, dataSource: dataSource)
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
    for (_, cell) in leaving { recycle(cell) }
    leaving.removeAll()
    for cell in vanishing { recycle(cell) }
    vanishing.removeAll()
    leavingCleanup?.cancel()
    cachingResume?.cancel()
    cachingResume = nil
    stopCaching()
  }

  private func load(_ cell: PhotoGridCellLayer, at index: Int, dataSource: any PhotoGridDataSource) {
    let key = ThumbnailKey(id: dataSource.itemID(at: index), bucket: bucket)
    cell.itemID = key.id
    if let image = pipeline.placeholder(for: key) {
      cell.setImage(image)
      if pipeline.cachedImage(for: key) != nil { return }
    }
    let quality: ImageRequestQuality = isScrollingFast ? .fast : .thumbnail
    // A fast request is never final for the bucket, so it isn't cached as one.
    let requestKey = isScrollingFast ? ThumbnailKey(id: key.id, bucket: .tiny) : key
    cell.ticket = pipeline.load(requestKey, from: dataSource.thumbnailSource, quality: quality) {
      [weak self, weak cell] image, _ in
      guard let cell, cell.itemID == key.id else { return }
      cell.setImage(image)
      self?.revealIfReady()
    }
  }

  /// Visible cells ask again at the current bucket, keeping what they show meanwhile.
  private func refreshImages() {
    guard let dataSource else { return }
    for (index, cell) in visible {
      cell.ticket?.cancel()
      load(cell, at: index, dataSource: dataSource)
    }
  }

  private func scheduleLeavingCleanup() {
    leavingCleanup?.cancel()
    leavingCleanup = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.glideDuration + 0.05))
      guard !Task.isCancelled, let self else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for (_, cell) in self.leaving { self.recycle(cell) }
      for cell in self.vanishing { self.recycle(cell) }
      CATransaction.commit()
      self.leaving.removeAll()
      self.vanishing.removeAll()
    }
  }

  /// Critically damped, as the system's own zooms are.
  private static func spring(keyPath: String) -> CASpringAnimation {
    let spring = CASpringAnimation(perceptualDuration: glideDuration, bounce: 0)
    spring.keyPath = keyPath
    spring.duration = spring.settlingDuration
    return spring
  }

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
  private func updateCaching(around rect: CGRect, velocity: CGFloat, dataSource: any PhotoGridDataSource) {
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
    let source = dataSource.thumbnailSource
    if cachingBucket != bucket {
      stopCaching()
      cachingBucket = bucket
    }
    let added = Self.subtract(range, cachingRange)
    let removed = Self.subtract(cachingRange, range)
    cachingRange = range
    let count = dataSource.itemCount
    let ids = { (ranges: [Range<Int>]) in ranges.flatMap { $0.clamped(to: 0..<count) }.map(dataSource.itemID(at:)) }
    let addedIDs = ids(added)
    let removedIDs = ids(removed)
    if !removedIDs.isEmpty { source.stopCaching(ids: removedIDs, pixelSize: bucket.pixelSize) }
    if !addedIDs.isEmpty { source.startCaching(ids: addedIDs, pixelSize: bucket.pixelSize) }
  }

  private func stopCaching() {
    if let cachingBucket, let source = dataSource?.thumbnailSource, !cachingRange.isEmpty {
      let count = dataSource?.itemCount ?? 0
      let ids = cachingRange.clamped(to: 0..<count).compactMap { dataSource?.itemID(at: $0) }
      source.stopCaching(ids: ids, pixelSize: cachingBucket.pixelSize)
    }
    cachingRange = 0..<0
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
