import AppIntents
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Column counts a pinch steps through, densest last.
public enum PhotoGridZoom {
  #if os(iOS)
    public static let columnSteps = [1, 2, 3, 4, 5, 7, 10, 14]
    public static let defaultColumns = 3
  #else
    /// On the Mac the step is a target cell width; columns follow the window width.
    public static let cellWidthSteps: [CGFloat] = [520, 360, 260, 190, 140, 104, 76, 56]
    public static let defaultStep = 4
  #endif
}

/// A context menu command for grid items.
public struct PhotoGridMenuItem {
  /// Where a command sits, as in Photos: quick actions as a row of icons at the top,
  /// then actions, then organizing, then destructive ones.
  public enum Group: Int, Comparable, Sendable {
    case quick, actions, organize, destructive

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public let title: String
  public let systemImage: String
  public let isDestructive: Bool
  public let group: Group
  /// A submenu ("Add To"); the action is unused when there are children.
  public let children: [PhotoGridMenuItem]
  public let action: @MainActor () -> Void

  public init(
    _ title: String, systemImage: String, isDestructive: Bool = false, group: Group? = nil,
    children: [PhotoGridMenuItem] = [], action: @escaping @MainActor () -> Void = {}
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isDestructive = isDestructive
    self.group = group ?? (isDestructive ? .destructive : .actions)
    self.children = children
    self.action = action
  }

  /// The items in display order, one array per group.
  static func grouped(_ items: [PhotoGridMenuItem]) -> [(group: Group, items: [PhotoGridMenuItem])] {
    Dictionary(grouping: items, by: \.group).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }
}

/// Grid behavior beyond the items themselves.
public struct PhotoGridOptions {
  /// iOS Select mode: taps toggle items and horizontal drags select ranges.
  public var isSelecting = false
  /// Called with the first visible item as the grid scrolls.
  public var onTopIndexChange: ((Int) -> Void)?
  /// Commands for the items a context menu applies to (the clicked item, or the whole
  /// selection when the click is inside it).
  public var menu: ((Set<Int>) -> [PhotoGridMenuItem])?
  /// Files for dragging items out of the grid (Finder, Mail and other apps on the Mac).
  public var dragItem: ((Int) -> PhotoGridDragItem?)?
  /// Where cells are on screen, for the zoom into and out of the viewer.
  public var proxy: PhotoGridProxy?
  /// Pinching out past the densest grid, which in Photos moves on to Months.
  public var onPinchPastDensest: (() -> Void)?
  /// Content starts or stops going under the top bar (iOS).
  public var onScrolledUnderBarChange: ((Bool) -> Void)?
  /// Space above the first row, below the bar (iOS).
  public var topPadding: CGFloat = 0
  /// How far from the bottom the last row ends, for a grid laid out under a bar UIKit
  /// doesn't report in its safe area, such as the floating search field (iOS).
  public var bottomInset: CGFloat?
  /// The newest items are last, as in Photos: the grid opens at its end, stays there as
  /// items change, and that end is where the tab bar grows back (iOS).
  public var startsAtEnd = false
  /// Align the last row and keep a visible item in place when reading more of a timeline.
  public var alignsNewestRow = false
  var positionOfItem: ((String) -> Int?)?
  var currentReloadToken: (() -> Int)?
  /// With `startsAtEnd`, the grid reaches or leaves its newest end (iOS).
  public var onAtEndChange: ((Bool) -> Void)?
  /// The first time the grid has items drawn on screen (iOS).
  public var onShowItems: (() -> Void)?
  /// How many items a saved image of the grid stands in for while it has none: it scrolls
  /// as far, so the bar over it already looks as it will (iOS).
  var placeholderCount = 0
  /// That image. It's drawn in the scroll view, so the system's bar effect covers it as it
  /// does the cells, and fades out when it's taken away (iOS).
  var placeholderImage: CGImage?

  public init(
    isSelecting: Bool = false, onTopIndexChange: ((Int) -> Void)? = nil,
    menu: ((Set<Int>) -> [PhotoGridMenuItem])? = nil, dragItem: ((Int) -> PhotoGridDragItem?)? = nil,
    proxy: PhotoGridProxy? = nil, onPinchPastDensest: (() -> Void)? = nil,
    onScrolledUnderBarChange: ((Bool) -> Void)? = nil, topPadding: CGFloat = 0, bottomInset: CGFloat? = nil,
    startsAtEnd: Bool = false, alignsNewestRow: Bool = false, onAtEndChange: ((Bool) -> Void)? = nil, onShowItems: (() -> Void)? = nil
  ) {
    self.isSelecting = isSelecting
    self.onTopIndexChange = onTopIndexChange
    self.menu = menu
    self.dragItem = dragItem
    self.proxy = proxy
    self.onPinchPastDensest = onPinchPastDensest
    self.onScrolledUnderBarChange = onScrolledUnderBarChange
    self.topPadding = topPadding
    self.bottomInset = bottomInset
    self.startsAtEnd = startsAtEnd
    self.alignsNewestRow = alignsNewestRow
    self.onAtEndChange = onAtEndChange
    self.onShowItems = onShowItems
  }
}

/// Asks a grid where an item's cell is, in the grid's own coordinates (the frame the
/// `PhotoGrid` view occupies), scrolling it into view first if asked to.
@MainActor
public final class PhotoGridProxy {
  var frameProvider: ((Int, _ reveal: Bool) -> CGRect?)?

  public init() {}

  public func frame(of index: Int, revealing: Bool = false) -> CGRect? { frameProvider?(index, revealing) }

  var windowFrameProvider: ((Int, _ reveal: Bool) -> CGRect?)?
  var hider: ((Int?) -> Void)?

  /// The cell's frame in window coordinates; with `revealing`, an item off screen is
  /// scrolled into view first.
  public func windowFrame(of index: Int, revealing: Bool = false) -> CGRect? { windowFrameProvider?(index, revealing) }

  /// Leaves a cell empty (or none) while its photo is drawn elsewhere.
  public func hide(_ index: Int?) { hider?(index) }

  var endScroller: (() -> Void)?
  /// Scrolls to the last items, animated.
  public func scrollToEnd() { endScroller?() }

  var snapshotter: (() -> CGImage?)?
  /// The cells on screen drawn into an image the grid's size, over its background; nil
  /// while they wait for their first images.
  public func snapshot() -> CGImage? { snapshotter?() }

  #if os(macOS)
    var focuser: (() -> Void)?
    /// Makes the grid take keyboard input.
    public func focus() { focuser?() }
    var windowGetter: (() -> NSWindow?)?
    /// The window the grid is in.
    public var window: NSWindow? { windowGetter?() }
  #endif

  #if DEBUG
    var stressRunner: ((TimeInterval) -> Void)?
    /// Flings through the grid for a while and logs frame times (`-UIScreen cloudGridStress`).
    public func runStress(seconds: TimeInterval) { stressRunner?(seconds) }
    var pinchStressRunner: ((TimeInterval) -> Void)?
    /// Pinches through every column count and back (`-UIScreen cloudPinchStress`).
    public func runPinchStress(seconds: TimeInterval) { pinchStressRunner?(seconds) }
  #endif
}

#if DEBUG && os(iOS)
  import QuartzCore

  /// Drives a scroll view for a while from a display link, recording how long each frame
  /// took and how long the app's own work per frame took, and logs a summary.
  @MainActor
  final class ScrollStress: NSObject {
    private let name: String
    private let deadline: CFTimeInterval
    private let step: (CFTimeInterval) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames: [Double] = []
    private var work: [Double] = []
    private static var running: [ScrollStress] = []

    init(name: String, seconds: TimeInterval, step: @escaping (CFTimeInterval) -> Void) {
      self.name = name
      self.deadline = CACurrentMediaTime() + seconds
      self.step = step
      super.init()
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      self.link = link
      NSLog("STRESS-START %@", name)
      Self.running.append(self)
    }

    @objc private func tick(_ link: CADisplayLink) {
      let now = link.timestamp
      if last > 0 { frames.append((now - last) * 1000) }
      last = now
      let start = CACurrentMediaTime()
      step(link.targetTimestamp - link.timestamp)
      work.append((CACurrentMediaTime() - start) * 1000)
      guard now >= deadline else { return }
      link.invalidate()
      report(budget: (link.targetTimestamp - link.timestamp) * 1000)
      Self.running.removeAll { $0 === self }
    }

    private func report(budget: Double) {
      let sorted = work.sorted()
      let hitches = frames.filter { $0 > budget * 1.5 }.count
      let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
      // NSLog, so the numbers are in the unified log as well as the console.
      NSLog(
        "STRESS %@ frames=%d hitches=%d worstFrame=%.1fms budget=%.1fms work p50=%.2fms p95=%.2fms max=%.2fms",
        name, frames.count, hitches, frames.max() ?? 0, budget, p(0.5), p(0.95), sorted.last ?? 0)
    }
  }
#endif

/// A file promised to a drag destination; it's exported only when dropped.
public struct PhotoGridDragItem: Sendable {
  public let fileName: String
  public let isVideo: Bool
  public let export: @Sendable () async throws -> URL

  public init(fileName: String, isVideo: Bool, export: @escaping @Sendable () async throws -> URL) {
    self.fileName = fileName
    self.isVideo = isVideo
    self.export = export
  }
}

/// The photo grid for SwiftUI. Change `reloadToken` when the items change and
/// `badgeToken` when only badges (favorite, backup state) change. Setting `scrollTarget`
/// scrolls that item to the top; the grid sets it back to nil.
public struct PhotoGrid: View {
  let dataSource: any PhotoGridDataSource
  let reloadToken: Int
  let badgeToken: Int
  @Binding var zoomStep: Int
  @Binding var selection: Set<Int>
  @Binding var scrollTarget: Int?
  let options: PhotoGridOptions
  let onOpen: (Int) -> Void

  public init(
    dataSource: any PhotoGridDataSource, reloadToken: Int, badgeToken: Int, zoomStep: Binding<Int>,
    selection: Binding<Set<Int>> = .constant([]), scrollTarget: Binding<Int?> = .constant(nil),
    options: PhotoGridOptions = PhotoGridOptions(), onOpen: @escaping (Int) -> Void
  ) {
    self.dataSource = dataSource
    self.reloadToken = reloadToken
    self.badgeToken = badgeToken
    self._zoomStep = zoomStep
    self._selection = selection
    self._scrollTarget = scrollTarget
    self.options = options
    self.onOpen = onOpen
  }

  public var body: some View {
    PhotoGridRepresentable(
      dataSource: dataSource, reloadToken: reloadToken, badgeToken: badgeToken, zoomStep: $zoomStep,
      selection: $selection, scrollTarget: $scrollTarget, options: options, onOpen: onOpen)
  }
}

@MainActor
final class PhotoGridCoordinator {
  var reloadToken = 0
  var badgeToken = 0
  var acceptsRowInput: Bool { options.currentReloadToken.map { $0() == reloadToken } ?? true }
  var options = PhotoGridOptions()
  var lastTopIndex: Int?
  var onOpen: (Int) -> Void = { _ in }
  var onZoom: (Int) -> Void = { _ in }
  var onSelect: (Set<Int>) -> Void = { _ in }
  /// Column steps SwiftUI may still hand back: the last one both agreed on and every one
  /// the grid reported since. While a pinch steps through several, an update can carry any
  /// of them, and applying it would bounce the grid between two steps forever. Any other
  /// value is a change from outside (the Mac's zoom commands).
  private var echoedZoomSteps: Set<Int> = []

  func zoomStepChanged(to step: Int) { echoedZoomSteps.insert(step) }

  /// Whether `step` from SwiftUI should be applied to a grid showing `current`.
  func shouldApplyZoomStep(_ step: Int, current: Int) -> Bool {
    if step == current {
      echoedZoomSteps = [step]
      return false
    }
    guard !echoedZoomSteps.contains(step) else { return false }
    // An outside command is already SwiftUI's value. Its callback may set the same
    // value without causing another update, so old echoes must be retired now.
    echoedZoomSteps = [step]
    return true
  }

  /// Nil until the first report, which always goes out.
  var lastScrolled: Bool?

  var lastAtEnd = true
  private var reportsPending = false
  private var pendingEnd = false
  private var pendingScrolled = false
  private var pendingTop = false

  func reportAtEnd(_ atEnd: Bool) {
    guard atEnd != lastAtEnd else { return }
    lastAtEnd = atEnd
    pendingEnd = true
    scheduleReports()
  }

  /// Whether content has moved under the top bar, reported only when that flips.
  func reportScrolled(_ scrolled: Bool) {
    guard scrolled != lastScrolled else { return }
    lastScrolled = scrolled
    pendingScrolled = true
    scheduleReports()
  }

  func reportTop(_ index: Int?, reloaded: Bool = false) {
    guard let index, reloaded || index != lastTopIndex else { return }
    lastTopIndex = index
    pendingTop = true
    scheduleReports()
  }

  func offsetPreservingCell(
    _ previous: [String: PhotoGridCellLayer]?, visible: CGRect, layout: PhotoGridLayout
  ) -> CGFloat? {
    guard let previous, let position = options.positionOfItem else { return nil }
    var best: CGRect?
    var offset: CGFloat?
    for (id, cell) in previous {
      let frame = cell.frame
      guard frame.intersects(visible),
        best.map({ frame.minY == $0.minY ? frame.minX < $0.minX : frame.minY < $0.minY }) ?? true,
        let index = position(id)
      else { continue }
      best = frame
      offset = layout.frame(at: index).minY - (frame.minY - visible.minY)
    }
    return offset
  }

  /// Native layout can run inside a representable update. Publish SwiftUI state after
  /// that pass, coalescing a fling's intermediate geometry into its latest values.
  private func scheduleReports() {
    guard !reportsPending else { return }
    reportsPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      reportsPending = false
      let end = pendingEnd
      let scrolled = pendingScrolled
      let top = pendingTop
      pendingEnd = false
      pendingScrolled = false
      pendingTop = false
      if end { options.onAtEndChange?(lastAtEnd) }
      if scrolled, let lastScrolled { options.onScrolledUnderBarChange?(lastScrolled) }
      if top, let lastTopIndex { options.onTopIndexChange?(lastTopIndex) }
    }
  }

  /// The clicked item, or the whole selection when the click is inside it.
  func menuTargets(for index: Int, selection: Set<Int>) -> Set<Int> {
    selection.contains(index) ? selection : [index]
  }
}

#if os(iOS)
  import UIKit

  private struct PhotoGridRepresentable: UIViewRepresentable {
    let dataSource: any PhotoGridDataSource
    let reloadToken: Int
    let badgeToken: Int
    @Binding var zoomStep: Int
    @Binding var selection: Set<Int>
    @Binding var scrollTarget: Int?
    let options: PhotoGridOptions
    let onOpen: (Int) -> Void

    func makeCoordinator() -> PhotoGridCoordinator { PhotoGridCoordinator() }

    func makeUIView(context: Context) -> PhotoGridUIView {
      let view = PhotoGridUIView()
      context.coordinator.options = options
      context.coordinator.reloadToken = reloadToken
      context.coordinator.badgeToken = badgeToken
      view.coordinator = context.coordinator
      view.zoomStep = zoomStep
      context.coordinator.zoomStepChanged(to: zoomStep)
      view.setDataSource(dataSource)
      view.showPlaceholder(options.placeholderImage)
      return view
    }

    func updateUIView(_ view: PhotoGridUIView, context: Context) {
      let coordinator = context.coordinator
      let insetChanged = coordinator.options.bottomInset != options.bottomInset
      let placeholderChanged = coordinator.options.placeholderCount != options.placeholderCount
      coordinator.options = options
      if placeholderChanged { view.placeholderChanged() }
      view.showPlaceholder(options.placeholderImage)
      if insetChanged { view.setNeedsLayout() }
      options.proxy?.frameProvider = { [weak view] index, reveal in view?.visibleFrame(of: index, revealing: reveal) }
      options.proxy?.endScroller = { [weak view] in view?.scrollToEnd() }
      options.proxy?.snapshotter = { [weak view] in view?.snapshotImage() }
      options.proxy?.windowFrameProvider = { [weak view] index, reveal in view?.windowFrame(of: index, revealing: reveal) }
      options.proxy?.hider = { [weak view] index in view?.renderer.hiddenIndex = index }
      #if DEBUG
        options.proxy?.stressRunner = { [weak view] seconds in view?.runStress(seconds: seconds) }
        options.proxy?.pinchStressRunner = { [weak view] seconds in view?.runPinchStress(seconds: seconds) }
      #endif
      coordinator.onOpen = onOpen
      coordinator.onZoom = { [weak coordinator] step in
        coordinator?.zoomStepChanged(to: step)
        if zoomStep != step { zoomStep = step }
      }
      coordinator.onSelect = { if selection != $0 { selection = $0 } }
      if coordinator.shouldApplyZoomStep(zoomStep, current: view.zoomStep) {
        view.setZoomStep(zoomStep, animated: true, anchor: nil)
      }
      if view.renderer.selection != selection { view.renderer.selection = selection }
      if view.renderer.dataSource !== dataSource || coordinator.reloadToken != reloadToken {
        coordinator.reloadToken = reloadToken
        coordinator.badgeToken = badgeToken
        view.setDataSource(dataSource)
      } else if coordinator.badgeToken != badgeToken {
        coordinator.badgeToken = badgeToken
        view.renderer.refreshBadges()
      }
      view.renderer.refreshThumbnailSourceIfNeeded(visibleRect: view.bounds)
      if let target = scrollTarget {
        view.scroll(to: target)
        DispatchQueue.main.async { scrollTarget = nil }
      }
    }

    static func dismantleUIView(_ view: PhotoGridUIView, coordinator: PhotoGridCoordinator) {
      view.renderer.tearDown()
    }
  }

  /// A context menu preview: one image filling its frame.
  final class PhotoPreviewController: UIViewController {
    private let imageView = UIImageView()
    private var token: ImageRequestToken?
    private var lockObservation: AnyCancellable?

    init(image: CGImage?, size: CGSize, identity: ThumbnailIdentity) {
      super.init(nibName: nil, bundle: nil)
      imageView.image = identity.isLocked ? nil : image.map { UIImage(cgImage: $0) }
      lockObservation = NotificationCenter.default.publisher(for: LockedItems.didLock)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          if identity.isLocked {
            self?.token?.cancel()
            self?.imageView.image = nil
          }
        }
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      imageView.backgroundColor = .secondarySystemBackground
      preferredContentSize = size
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = imageView }

    func load(identity: ThumbnailIdentity, from source: any ThumbnailSource, pixelSize: CGSize) {
      guard !identity.isLocked else { return }
      token = source.requestImage(id: identity.id, pixelSize: pixelSize, quality: .display) { [weak self] image, _ in
        let box = UncheckedImage(image)
        Task { @MainActor in
          if !identity.isLocked { self?.imageView.image = UIImage(cgImage: box.image) }
        }
      }
    }

    deinit { token?.cancel() }
  }

  private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  final class PhotoGridUIView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    UIContextMenuInteractionDelegate
  {
    let renderer = PhotoGridRenderer()
    weak var coordinator: PhotoGridCoordinator?
    var zoomStep = PhotoGridZoom.columnSteps.firstIndex(of: PhotoGridZoom.defaultColumns) ?? 3
    private var lastOffset: CGFloat = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var velocity: CGFloat = 0
    private var pinchAnchor: (index: Int, viewportY: CGFloat)?
    private var dragSelection: (start: Int, selecting: Bool, base: Set<Int>)?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
      super.init(frame: frame)
      delegate = self
      alwaysBounceVertical = true
      // Photos under the bar fade from clear into blur toward the top, as in Photos.
      topEdgeEffect.style = .soft
      backgroundColor = .systemBackground
      layer.addSublayer(renderer.contentLayer)
      // A reveal can come from a SwiftUI update, which mustn't change state itself.
      renderer.onReveal = { [weak self] in
        DispatchQueue.main.async {
          self?.reportScrolledUnderBar()
          self?.reportShowingItems()
        }
      }
      // Posted from whichever thread a sync runs on; on the main one it's handled at once.
      lockObserver = NotificationCenter.default.addObserver(forName: LockedItems.didLock, object: nil, queue: .main) {
        [weak self] _ in
        // The picture may show what was just locked, even while it fades.
        MainActor.assumeIsolated { self?.endPlaceholder() }
      }
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
      addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
      let selectPan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectPan(_:)))
      selectPan.delegate = self
      addGestureRecognizer(selectPan)
      self.selectPan = selectPan
      panGestureRecognizer.require(toFail: selectPan)
      addInteraction(UIContextMenuInteraction(delegate: self))
      isAccessibilityElement = false
      shouldGroupAccessibilityChildren = true
      // The cells are layers, so the grid tells Siri itself which photos are where.
      appEntityUIElementProvider = { view, context in
        MainActor.assumeIsolated {
          guard let grid = view as? PhotoGridUIView else { return [] }
          return grid.renderer.siriElements(context, visible: grid.bounds)
        }
      }
    }

    isolated deinit {
      if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Photos under the top bar darken it; not before they're drawn, or the bar goes dark
    /// over an empty grid while the first images load (nor light, before there are any).
    private func reportScrolledUnderBar() {
      guard renderer.isShowing, renderer.layout.itemCount > 0 else { return }
      coordinator?.reportScrolled(contentOffset.y + adjustedContentInset.top > 4)
    }

    private var hasShownItems = false
    private var shownTime: CFTimeInterval?
    private var firstPixelsTime: CFTimeInterval?
    private var isCheckingPixels = false

    /// Once, when items are first drawn: right away if their images were cached, else
    /// when the renderer reveals them.
    private func reportShowingItems() {
      guard !hasShownItems, renderer.hasPixels(in: bounds) else { return }
      // A saved screen stays until every cell under it has its image, or they'd flash.
      if placeholderView != nil, !renderer.hasAllPixels(in: bounds) {
        let now = CACurrentMediaTime()
        if firstPixelsTime == nil { firstPixelsTime = now }
        if let first = firstPixelsTime, now - first < 2.5 {
          checkPixels()
          return
        }
      }
      hasShownItems = true
      shownTime = CACurrentMediaTime()
      // Layout can run inside a SwiftUI update, which mustn't change state itself.
      DispatchQueue.main.async {
        self.reportScrolledUnderBar()
        self.coordinator?.options.onShowItems?()
      }
    }

    private func checkPixels() {
      guard !isCheckingPixels else { return }
      isCheckingPixels = true
      Task { [weak self] in
        while let self, !self.hasShownItems, self.placeholderView != nil {
          try? await Task.sleep(for: .milliseconds(50))
          if let first = self.firstPixelsTime, CACurrentMediaTime() - first >= 2.5 {
            self.endPlaceholder()
          } else {
            self.reportShowingItems()
          }
        }
        self?.isCheckingPixels = false
      }
    }

    /// The user is at the grid itself, or what the image shows mustn't be seen.
    private func endPlaceholder() {
      guard let view = placeholderView else { return }
      view.layer.removeAllAnimations()
      view.removeFromSuperview()
      placeholderView = nil
      isPlaceholderOver = true
      guard !hasShownItems else { return }
      hasShownItems = true
      shownTime = CACurrentMediaTime()
      DispatchQueue.main.async {
        self.reportScrolledUnderBar()
        self.coordinator?.options.onShowItems?()
      }
    }

    func snapshotImage() -> CGImage? {
      guard renderer.hasPixels(in: bounds), !renderer.hasLockedPixels(in: bounds), bounds.width > 0, bounds.height > 0 else { return nil }
      let format = UIGraphicsImageRendererFormat(for: traitCollection)
      format.opaque = true
      // The renderer's bounds are the visible part of the content, so the cells draw where
      // they are on screen.
      let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
        (backgroundColor ?? .systemBackground).resolvedColor(with: traitCollection).setFill()
        context.fill(bounds)
        renderer.contentLayer.render(in: context.cgContext)
      }
      return image.cgImage
    }

    /// The bars follow this grid's scrolling (a large title collapses, the tab bar
    /// shrinks): SwiftUI only finds its own scroll views for that.
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else {
        // The display link holds the grid until it's stopped.
        return stopSelectScroll()
      }
      var responder = next
      while let current = responder, !(current is UITabBarController) {
        (current as? UIViewController)?.setContentScrollView(self, for: [.top, .bottom])
        responder = current.next
      }
    }

    private var columns: Int { PhotoGridZoom.columnSteps[min(max(zoomStep, 0), PhotoGridZoom.columnSteps.count - 1)] }

    func setDataSource(_ dataSource: any PhotoGridDataSource) {
      cancelRowGestures()
      let fromEnd = pinnedToEnd ? 0 : max(0, endOffset - contentOffset.y)
      // The same library with items added or removed animates; a new one just appears.
      let sameSource = renderer.dataSource === dataSource && dataSource.itemCount > 0
      // What the launch's last reads and first sync change just appears: cells growing in
      // and shrinking away as the app opens look like a glitch.
      let isSettled = shownTime.map { CACurrentMediaTime() - $0 > 4 } ?? false
      let animates = sameSource && isSettled && window != nil && !UIAccessibility.isReduceMotionEnabled
      let oldOffset = contentOffset.y
      let previous = sameSource ? renderer.detachCells() : nil
      if !sameSource { renderer.tearDown() }
      renderer.dataSource = dataSource
      renderer.displayScale = traitCollection.displayScale
      let layout = makeLayout()
      let anchor = pinnedToEnd ? nil : coordinator?.offsetPreservingCell(previous, visible: bounds, layout: layout)
      isChangingColumns = true
      keepingEnd {
        contentSize = CGSize(width: bounds.width, height: contentHeight(layout))
        // Items added or removed above stay out of sight: the grid keeps its place
        // counted from the newest end.
        if startsAtEnd {
          contentOffset.y = min(endOffset, max(-adjustedContentInset.top, anchor ?? (endOffset - fromEnd)))
        }
      }
      isChangingColumns = false
      renderer.setLayout(layout, visibleRect: bounds, populate: false)
      if let previous {
        renderer.reloadData(visibleRect: bounds, previous: previous, shift: contentOffset.y - oldOffset, animated: animates)
      } else {
        renderer.reloadData(visibleRect: bounds)
      }
      accessibilityCache = nil
      coordinator?.reportTop(renderer.topIndex(atY: contentOffset.y + adjustedContentInset.top), reloaded: true)
    }

    func windowFrame(of index: Int, revealing: Bool) -> CGRect? {
      guard visibleFrame(of: index, revealing: revealing) != nil else { return nil }
      layoutIfNeeded()
      return convert(renderer.layout.frame(at: index), to: nil)
    }

    /// To the newest items with a scroll, as when Library is chosen again in Photos. From
    /// far away it starts a few screens out, so it doesn't race through the library.
    func scrollToEnd() {
      endPlaceholder()
      let end = endOffset
      guard !UIAccessibility.isReduceMotionEnabled else {
        contentOffset.y = end
        return
      }
      let runUp = bounds.height * 3
      if end - contentOffset.y > runUp { contentOffset.y = end - runUp }
      setContentOffset(CGPoint(x: 0, y: end), animated: true)
    }

    private var placeholderView: UIImageView?
    private var lockObserver: (any NSObjectProtocol)?
    private var isPlaceholderOver = false

    func showPlaceholder(_ image: CGImage?) {
      guard let image else {
        guard let view = placeholderView else { return }
        // It fades only into the live grid.
        guard hasShownItems else { return endPlaceholder() }
        guard !isPlaceholderOver else { return }
        isPlaceholderOver = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3) {
          view.alpha = 0
        } completion: { [weak self] _ in
          view.removeFromSuperview()
          if self?.placeholderView === view { self?.placeholderView = nil }
        }
        return
      }
      guard placeholderView == nil, !isPlaceholderOver else { return }
      let view = UIImageView(image: UIImage(cgImage: image))
      view.isUserInteractionEnabled = false
      view.frame = bounds
      // UIKit's bar effects are the scroll view's first subviews: under them, over the cells.
      if let effects = subviews.first { insertSubview(view, belowSubview: effects) } else { addSubview(view) }
      placeholderView = view
    }

    func placeholderChanged() {
      guard renderer.layout.itemCount == 0, bounds.width > 0 else { return }
      keepingEnd {
        contentSize = CGSize(width: bounds.width, height: contentHeight(makeLayout()))
        positionAtEndIfPinned()
      }
    }

    private var startsAtEnd: Bool { coordinator?.options.startsAtEnd == true }
    /// With `startsAtEnd`, whether the grid shows (and keeps showing) its last row.
    private var pinnedToEnd = true
    private var lastInsets: UIEdgeInsets = .zero
    private var isKeepingEnd = false
    private var isChangingColumns = false
    /// Where the pinch started, in content coordinates: the grid scales about it.
    private var pinchPoint: CGPoint = .zero
    private var endOffset: CGFloat {
      max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }

    /// Runs a change of size or position that mustn't count as the user leaving the end.
    private func keepingEnd(_ change: () -> Void) {
      guard startsAtEnd else { return change() }
      isKeepingEnd = true
      change()
      isKeepingEnd = false
    }

    private func contentHeight(_ layout: PhotoGridLayout) -> CGFloat {
      guard layout.itemCount == 0, let count = coordinator?.options.placeholderCount, count > 0 else { return layout.contentHeight }
      return makeLayout(itemCount: count).contentHeight
    }

    private func makeLayout() -> PhotoGridLayout { makeLayout(itemCount: renderer.dataSource?.itemCount ?? 0) }

    private func makeLayout(itemCount: Int) -> PhotoGridLayout {
      PhotoGridLayout(
        columns: columns, spacing: columns >= 7 ? 1 : 2, width: bounds.width,
        itemCount: itemCount, pixelScale: traitCollection.displayScale,
        alignsNewestRow: coordinator?.options.alignsNewestRow == true)
    }

    override func layoutSubviews() {
      let top = coordinator?.options.topPadding ?? 0
      if contentInset.top != top { contentInset.top = top }
      if let bottomInset = coordinator?.options.bottomInset {
        let bottom = max(0, bottomInset - safeAreaInsets.bottom)
        if contentInset.bottom != bottom {
          contentInset.bottom = bottom
          verticalScrollIndicatorInsets.bottom = bottom
        }
      }
      super.layoutSubviews()
      defer {
        if let placeholderView {
          // A picture of another size (rotated, resized) would show other photos than the taps reach.
          if placeholderView.frame.size != .zero, placeholderView.frame.size != bounds.size { endPlaceholder() }
          self.placeholderView?.frame = bounds
        }
      }
      guard !isChangingColumns else { return }
      let changesLayout = renderer.layout.width != bounds.width || renderer.displayScale != traitCollection.displayScale
      if changesLayout {
        renderer.displayScale = traitCollection.displayScale
        let layout = makeLayout()
        keepingEnd {
          contentSize = CGSize(width: bounds.width, height: contentHeight(layout))
          positionAtEndIfPinned()
        }
        renderer.setLayout(layout, visibleRect: bounds, populate: pendingScroll == nil)
      } else {
        keepingEnd { positionAtEndIfPinned() }
      }
      if let pendingScroll, bounds.width > 0, bounds.height > 0 {
        scroll(to: pendingScroll)
      } else if !changesLayout {
        renderer.update(visibleRect: bounds, velocity: velocity)
      }
      reportShowingItems()
    }

    override func adjustedContentInsetDidChange() {
      super.adjustedContentInsetDidChange()
      setNeedsLayout()
    }

    private func positionAtEndIfPinned() {
      lastInsets = adjustedContentInset
      if startsAtEnd, pinnedToEnd, !isTracking, !isDecelerating, contentOffset.y != endOffset {
        contentOffset.y = endOffset
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !isChangingColumns else {
        lastInsets = adjustedContentInset
        lastOffset = contentOffset.y
        return
      }
      let now = CACurrentMediaTime()
      let offset = contentOffset.y
      let elapsed = now - lastScrollTime
      if elapsed > 0, elapsed < 0.2 {
        velocity = (offset - lastOffset) / CGFloat(elapsed)
      } else {
        velocity = 0
      }
      lastOffset = offset
      lastScrollTime = now
      // Rebuilt only when other cells come into view: new elements every frame would drop
      // VoiceOver's focus.
      let range = renderer.layout.indices(in: bounds)
      if range != accessibilityRange {
        accessibilityRange = range
        accessibilityCache = nil
      }
      coordinator?.reportTop(renderer.topIndex(atY: offset + adjustedContentInset.top))
      reportScrolledUnderBar()
      // A new grid gets its safe area late, and UIKit moves the content with it: that isn't
      // the user leaving the end, so the next layout puts the grid back there.
      let insetsChanged = adjustedContentInset != lastInsets
      lastInsets = adjustedContentInset
      if startsAtEnd, insetsChanged, pinnedToEnd, !isTracking, !isDecelerating {
        setNeedsLayout()
      } else if startsAtEnd, !isKeepingEnd {
        pinnedToEnd = offset >= endOffset - 2
        coordinator?.reportAtEnd(pinnedToEnd)
      }
    }

    /// The cell's frame in the view's visible area; with `revealing`, an item off screen
    /// is scrolled to the middle first.
    func visibleFrame(of index: Int, revealing: Bool) -> CGRect? {
      guard index >= 0, index < renderer.layout.itemCount else { return nil }
      let frame = renderer.layout.frame(at: index)
      let visible = bounds.inset(by: adjustedContentInset)
      // Only a cell that's mostly hidden scrolls into view; moving the grid for one that
      // is partly under a bar makes it jump just before the zoom lands.
      let shown = visible.intersection(frame)
      if revealing, shown.isNull || shown.height < frame.height / 2 {
        let maxOffset = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let target = frame.midY - adjustedContentInset.top - visible.height / 2
        lastInsets = adjustedContentInset
        endPlaceholder()
        contentOffset.y = min(maxOffset, max(-adjustedContentInset.top, target))
        settle()
      }
      return frame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
    }

    #if DEBUG
      /// A fast fling down and back up, about three screens a second each way.
      func runStress(seconds: TimeInterval) {
        var direction: CGFloat = 1
        _ = ScrollStress(name: "grid", seconds: seconds) { [weak self] frame in
          guard let self else { return }
          let maxOffset = self.contentSize.height - self.bounds.height
          var next = self.contentOffset.y + direction * self.bounds.height * 3 * frame
          if next > maxOffset || next < -self.adjustedContentInset.top {
            direction = -direction
            next = min(max(next, -self.adjustedContentInset.top), maxOffset)
          }
          self.contentOffset.y = next
          self.layoutIfNeeded()
        }
      }

      /// A pinch at a finger's pace, about a second per column count, through every
      /// count and back, the way the gesture drives it.
      func runPinchStress(seconds: TimeInterval) {
        var scale: CGFloat = 1
        var direction: CGFloat = 1
        let point = CGPoint(x: bounds.midX, y: contentOffset.y + bounds.height / 2)
        startPinch(at: point)
        _ = ScrollStress(name: "pinch", seconds: seconds) { [weak self] frame in
          guard let self else { return }
          if self.zoomStep == 0 { direction = -1 }
          if self.zoomStep == PhotoGridZoom.columnSteps.count - 1 { direction = 1 }
          scale *= pow(1.3, CGFloat(frame) * 1.6 * direction)
          let point = CGPoint(x: self.bounds.midX, y: self.contentOffset.y + self.bounds.height / 2)
          self.pinch(to: scale, at: point, restart: { scale = 1 }, end: {})
          self.layoutIfNeeded()
        }
      }
    #endif

    /// A scroll asked for before the grid had its size (it was just made), done once it has.
    private var pendingScroll: Int?

    func scroll(to index: Int) {
      guard bounds.width > 0, bounds.height > 0, renderer.layout.width == bounds.width else {
        pendingScroll = index
        return
      }
      pendingScroll = nil
      endPlaceholder()
      guard index >= 0, index < renderer.layout.itemCount else { return }
      let maxOffset = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
      let target = min(maxOffset, renderer.layout.frame(at: index).minY - adjustedContentInset.top)
      lastInsets = adjustedContentInset
      setContentOffset(CGPoint(x: 0, y: max(-adjustedContentInset.top, target)), animated: false)
      if startsAtEnd {
        pinnedToEnd = contentOffset.y >= endOffset - 2
        coordinator?.reportAtEnd(pinnedToEnd)
      }
      settle()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { endPlaceholder() }

    private func settle() {
      velocity = 0
      renderer.update(visibleRect: bounds, atRest: true)
      reportScrolledUnderBar()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard placeholderView == nil else { return endPlaceholder() }
      guard let index = renderer.index(at: recognizer.location(in: self)) else { return }
      guard coordinator?.acceptsRowInput == true else { return }
      if coordinator?.options.isSelecting == true || !renderer.selection.isEmpty {
        var selection = renderer.selection
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        renderer.selection = selection
        coordinator?.onSelect(selection)
      } else {
        coordinator?.onOpen(index)
      }
    }

    /// The grid follows the fingers, as in Photos: it scales live until the pinch reaches
    /// the next column count, then glides there and keeps following from it.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began:
        endPlaceholder()
        startPinch(at: recognizer.location(in: self))
      case .changed:
        pinch(
          to: recognizer.scale, at: recognizer.location(in: self), restart: { recognizer.scale = 1 },
          end: {
            // Ends this pinch, so the next one starts fresh.
            recognizer.isEnabled = false
            recognizer.isEnabled = true
          })
      default:
        endPinch()
      }
    }

    private func startPinch(at point: CGPoint) {
      pinchPoint = point
      let index = renderer.index(at: point) ?? renderer.layout.indices(in: bounds).lowerBound
      pinchAnchor = (index, point.y - contentOffset.y)
    }

    private func pinch(to scale: CGFloat, at point: CGPoint, restart: () -> Void, end: () -> Void) {
      let densest = PhotoGridZoom.columnSteps.count - 1
      let pastDensest = coordinator?.options.onPinchPastDensest
      // The fingers' place on screen; the content under it moves with the column change.
      let viewport = CGPoint(x: point.x, y: point.y - contentOffset.y)
      if scale > 1.3, zoomStep > 0 {
        setZoomStep(zoomStep - 1, animated: true, anchor: pinchAnchor)
        restart()
        startPinch(at: CGPoint(x: viewport.x, y: viewport.y + contentOffset.y))
      } else if scale < 0.77, zoomStep < densest {
        setZoomStep(zoomStep + 1, animated: true, anchor: pinchAnchor)
        restart()
        startPinch(at: CGPoint(x: viewport.x, y: viewport.y + contentOffset.y))
      } else if scale < 0.6, let pastDensest {
        end()
        endPinch()
        pastDensest()
      } else {
        // Past the last column count the grid only gives a little.
        let atLimit = (scale > 1 && zoomStep == 0) || (scale < 1 && zoomStep == densest && pastDensest == nil)
        // Half the fingers' scale: enough to feel attached, without showing much empty
        // space beside a shrinking grid.
        let visible = 1 + (scale - 1) * (atLimit ? 0.2 : 0.5)
        renderer.setLiveScale(visible, about: pinchPoint, visibleRect: bounds)
      }
    }

    private func endPinch() {
      pinchAnchor = nil
      renderer.endLiveScale(visibleRect: bounds, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: Drag to select

    private static let backSwipeEdgeWidth: CGFloat = 40
    private weak var selectPan: UIPanGestureRecognizer?

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      // UIKit also asks this view about gestures on its ancestors, swipe back among them.
      if recognizer.view !== self {
        // In Select mode a sideways drag selects, except from the screen's edge.
        let x = recognizer.location(in: nil).x
        let fromEdge = effectiveUserInterfaceLayoutDirection == .rightToLeft ? (window?.bounds.width ?? bounds.width) - x : x
        return coordinator?.options.isSelecting != true || !(recognizer is UIPanGestureRecognizer)
          || fromEdge <= Self.backSwipeEdgeWidth
      }
      guard recognizer === selectPan else { return super.gestureRecognizerShouldBegin(recognizer) }
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      // Only a sideways drag in Select mode selects; vertical drags still scroll.
      guard coordinator?.options.isSelecting == true else { return false }
      let velocity = pan.velocity(in: self)
      return abs(velocity.x) > abs(velocity.y) && renderer.index(at: pan.location(in: self)) != nil
    }

    private func cancelRowGestures() {
      dragSelection = nil
      stopSelectScroll()
    }

    @objc private func handleSelectPan(_ recognizer: UIPanGestureRecognizer) {
      guard coordinator?.acceptsRowInput == true else { return cancelRowGestures() }
      let point = recognizer.location(in: self)
      switch recognizer.state {
      case .began:
        guard let start = renderer.index(at: point) else { return }
        let base = renderer.selection
        dragSelection = (start, !base.contains(start), base)
        applyDragSelection(to: start)
      case .changed:
        guard dragSelection != nil else { return }
        selectPoint = CGPoint(x: point.x, y: point.y - contentOffset.y)
        updateSelectScroll()
        extendDragSelection()
      default:
        cancelRowGestures()
      }
    }

    /// The finger's place on screen during a drag to select.
    private var selectPoint: CGPoint = .zero
    private var selectScroll: CADisplayLink?
    /// Points per second, down when positive.
    private var selectScrollSpeed: CGFloat = 0

    private func extendDragSelection() {
      let point = CGPoint(x: min(max(selectPoint.x, 0), bounds.width - 1), y: selectPoint.y + contentOffset.y)
      if let index = renderer.index(at: point) ?? renderer.topIndex(atY: point.y) { applyDragSelection(to: index) }
    }

    /// Near the top or bottom edge the grid scrolls under the finger, also while it's held
    /// still, and faster the closer it is to the edge, as in Photos.
    private func updateSelectScroll() {
      let top = adjustedContentInset.top + 40
      let bottom = bounds.height - 80
      if selectPoint.y > bottom {
        selectScrollSpeed = 240 + min(1, (selectPoint.y - bottom) / 80) * 1_100
      } else if selectPoint.y < top {
        selectScrollSpeed = -(240 + min(1, (top - selectPoint.y) / 40) * 1_100)
      } else {
        return stopSelectScroll()
      }
      guard selectScroll == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(selectScrollTick(_:)))
      link.add(to: .main, forMode: .common)
      selectScroll = link
    }

    private func stopSelectScroll() {
      selectScroll?.invalidate()
      selectScroll = nil
    }

    @objc private func selectScrollTick(_ link: CADisplayLink) {
      guard dragSelection != nil, coordinator?.acceptsRowInput == true else { return cancelRowGestures() }
      let step = selectScrollSpeed * CGFloat(link.targetTimestamp - link.timestamp)
      let next = min(endOffset, max(-adjustedContentInset.top, contentOffset.y + step))
      guard next != contentOffset.y else { return }
      contentOffset.y = next
      extendDragSelection()
    }

    private func applyDragSelection(to index: Int) {
      guard let drag = dragSelection else { return }
      let range = Set(min(drag.start, index)...max(drag.start, index))
      let selection = drag.selecting ? drag.base.union(range) : drag.base.subtracting(range)
      guard selection != renderer.selection else { return }
      renderer.selection = selection
      coordinator?.onSelect(selection)
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }

    // MARK: Context menu

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard placeholderView == nil, let coordinator, coordinator.acceptsRowInput, let menu = coordinator.options.menu,
        let index = renderer.index(at: location)
      else {
        return nil
      }
      let targets = coordinator.menuTargets(for: index, selection: renderer.selection)
      let items = menu(targets)
      guard !items.isEmpty else { return nil }
      // One item gets a large preview of the whole photo; a selection keeps the cell.
      let showsPreview = targets.count == 1
      return UIContextMenuConfiguration(
        identifier: index as NSNumber, previewProvider: showsPreview ? { [weak self] in self?.makePreview(at: index) } : nil
      ) { _ in
        UIMenu(
          children: PhotoGridMenuItem.grouped(items).map { group, items in
            let section = UIMenu(options: .displayInline, children: items.map(Self.menuElement))
            if group == .quick { section.preferredElementSize = .medium }
            return section
          })
      }
    }

    private static func menuElement(_ item: PhotoGridMenuItem) -> UIMenuElement {
      guard item.children.isEmpty else {
        return UIMenu(
          title: item.title, image: UIImage(systemName: item.systemImage), children: item.children.map(menuElement))
      }
      return UIAction(
        title: item.title, image: UIImage(systemName: item.systemImage),
        attributes: item.isDestructive ? .destructive : []
      ) { _ in item.action() }
    }

    /// The photo at its own shape, as large as fits above the menu; the grid's thumbnail
    /// shows at once and a sharper image replaces it.
    private func makePreview(at index: Int) -> UIViewController? {
      guard let dataSource = renderer.dataSource, index < dataSource.itemCount else { return nil }
      let identity = dataSource.thumbnailIdentity(at: index)
      let cell = renderer.cellLayer(at: index) as? PhotoGridCellLayer
      guard !identity.isLocked, cell?.thumbnailIdentity?.isLocked != true else { return nil }
      let cellImage = cell?.contents.flatMap { contents -> CGImage? in
        CFGetTypeID(contents as CFTypeRef) == CGImage.typeID ? (contents as! CGImage) : nil
      }
      let ratio =
        dataSource.aspectRatio(at: index)
        ?? cellImage.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
      let screen = window?.bounds.size ?? bounds.size
      let maxWidth = screen.width - 32
      let maxHeight = screen.height * 0.55
      var size = CGSize(width: maxWidth, height: maxWidth / max(ratio, 0.01))
      if size.height > maxHeight { size = CGSize(width: maxHeight * ratio, height: maxHeight) }
      let preview = PhotoPreviewController(image: cellImage, size: size, identity: identity)
      preview.load(
        identity: identity, from: dataSource.thumbnailSource,
        pixelSize: CGSize(width: size.width * traitCollection.displayScale, height: size.height * traitCollection.displayScale))
      return preview
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
      animator: any UIContextMenuInteractionCommitAnimating
    ) {
      // Tapping the preview opens the photo, as in Photos.
      guard let index = (configuration.identifier as? NSNumber)?.intValue else { return }
      animator.preferredCommitStyle = .dismiss
      animator.addCompletion { [weak self] in self?.coordinator?.onOpen(index) }
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
      highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? { preview(for: identifier) }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
      dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? { preview(for: identifier) }

    private func preview(for identifier: any NSCopying) -> UITargetedPreview? {
      guard let index = (identifier as? NSNumber)?.intValue, let cell = renderer.cellLayer(at: index) else { return nil }
      let frame = renderer.layout.frame(at: index)
      let snapshot = UIView(frame: CGRect(origin: .zero, size: frame.size))
      snapshot.layer.contents = cell.contents
      snapshot.layer.contentsRect = cell.contentsRect
      snapshot.layer.contentsGravity = .resizeAspectFill
      let parameters = UIPreviewParameters()
      parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: 4)
      return UITargetedPreview(
        view: snapshot, parameters: parameters, target: UIPreviewTarget(container: self, center: CGPoint(x: frame.midX, y: frame.midY)))
    }

    func setZoomStep(_ step: Int, animated: Bool, anchor: (index: Int, viewportY: CGFloat)?) {
      let clamped = min(max(step, 0), PhotoGridZoom.columnSteps.count - 1)
      guard clamped != zoomStep else { return }
      let anchor = anchor ?? renderer.layout.indices(in: bounds).first.map { ($0, renderer.layout.frame(at: $0).midY - contentOffset.y) }
      zoomStep = clamped
      let layout = makeLayout()
      let oldOffset = contentOffset.y
      let staysAtEnd = startsAtEnd && pinnedToEnd
      // The old cells stay as they are until the renderer moves them.
      isChangingColumns = true
      keepingEnd {
        contentSize = CGSize(width: bounds.width, height: contentHeight(layout))
        let maxOffset = max(-adjustedContentInset.top, layout.contentHeight - bounds.height + adjustedContentInset.bottom)
        if staysAtEnd {
          contentOffset.y = maxOffset
        } else if let anchor {
          contentOffset.y = min(
            maxOffset, max(-adjustedContentInset.top, layout.offsetKeeping(index: anchor.index, atViewportY: anchor.viewportY)))
        }
      }
      isChangingColumns = false
      renderer.setLayout(
        layout, visibleRect: bounds, animated: animated && !UIAccessibility.isReduceMotionEnabled,
        shift: contentOffset.y - oldOffset)
      coordinator?.reportTop(renderer.topIndex(atY: contentOffset.y + adjustedContentInset.top))
      coordinator?.onZoom(clamped)
      accessibilityCache = nil
    }

    // MARK: Accessibility

    private var accessibilityCache: [UIAccessibilityElement]?
    private var accessibilityRange: Range<Int>?

    override var accessibilityElements: [Any]? {
      get {
        if let accessibilityCache { return accessibilityCache }
        guard let dataSource = renderer.dataSource else { return [] }
        let elements = renderer.layout.indices(in: bounds).map { index -> UIAccessibilityElement in
          let element = UIAccessibilityElement(accessibilityContainer: self)
          element.accessibilityLabel = dataSource.accessibilityLabel(at: index)
          element.accessibilityTraits = renderer.selection.contains(index) ? [.image, .selected] : .image
          element.accessibilityFrameInContainerSpace = renderer.layout.frame(at: index)
          return element
        }
        accessibilityCache = elements
        return elements
      }
      set {}
    }
  }

#else
  import AppKit

  private struct PhotoGridRepresentable: NSViewRepresentable {
    let dataSource: any PhotoGridDataSource
    let reloadToken: Int
    let badgeToken: Int
    @Binding var zoomStep: Int
    @Binding var selection: Set<Int>
    @Binding var scrollTarget: Int?
    let options: PhotoGridOptions
    let onOpen: (Int) -> Void

    func makeCoordinator() -> PhotoGridCoordinator { PhotoGridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = NSScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.drawsBackground = false
      scrollView.automaticallyAdjustsContentInsets = true
      let grid = PhotoGridNSView()
      context.coordinator.options = options
      options.proxy?.endScroller = { [weak grid] in grid?.scrollToEnd() }
      grid.coordinator = context.coordinator
      grid.zoomStep = zoomStep
      context.coordinator.zoomStepChanged(to: zoomStep)
      scrollView.documentView = grid
      context.coordinator.reloadToken = reloadToken
      context.coordinator.badgeToken = badgeToken
      options.proxy?.snapshotter = { [weak grid] in grid?.snapshotImage() }
      options.proxy?.windowGetter = { [weak grid] in grid?.window }
      options.proxy?.focuser = { [weak grid] in
        guard let grid else { return }
        grid.window?.makeFirstResponder(grid)
      }
      grid.attach(to: scrollView)
      grid.setDataSource(dataSource)
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      guard let grid = scrollView.documentView as? PhotoGridNSView else { return }
      let coordinator = context.coordinator
      coordinator.options = options
      coordinator.onOpen = onOpen
      coordinator.onZoom = { [weak coordinator] step in
        coordinator?.zoomStepChanged(to: step)
        if zoomStep != step { zoomStep = step }
      }
      coordinator.onSelect = { if selection != $0 { selection = $0 } }
      if coordinator.shouldApplyZoomStep(zoomStep, current: grid.zoomStep) {
        grid.setZoomStep(zoomStep, anchor: nil)
      }
      if grid.renderer.selection != selection { grid.renderer.selection = selection }
      grid.renderer.showsSelectionCircles = !selection.isEmpty || options.isSelecting
      if grid.renderer.dataSource !== dataSource || coordinator.reloadToken != reloadToken {
        coordinator.reloadToken = reloadToken
        coordinator.badgeToken = badgeToken
        grid.setDataSource(dataSource)
      } else if coordinator.badgeToken != badgeToken {
        coordinator.badgeToken = badgeToken
        grid.renderer.refreshBadges()
      }
      grid.renderer.refreshThumbnailSourceIfNeeded(visibleRect: grid.visibleRect)
      if let target = scrollTarget {
        grid.scroll(to: target)
        DispatchQueue.main.async { scrollTarget = nil }
      }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: PhotoGridCoordinator) {
      (scrollView.documentView as? PhotoGridNSView)?.renderer.tearDown()
    }
  }

  final class PhotoGridNSView: NSView {
    let renderer = PhotoGridRenderer()
    weak var coordinator: PhotoGridCoordinator?
    var zoomStep = PhotoGridZoom.defaultStep
    private weak var scrollView: NSScrollView?
    private var lastOffset: CGFloat = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var velocity: CGFloat = 0
    private var settleWork: DispatchWorkItem?
    private var magnification: CGFloat = 0
    private var pinchPoint: NSPoint = .zero
    private var isChangingColumns = false
    private var selectionAnchor: Int?
    /// Where the arrow keys move from; with ⇧ the range runs from the anchor to here.
    private var keyboardCursor: Int?
    private var rubberBand: (origin: NSPoint, base: Set<Int>)?
    /// A press on an item: dragging it starts a file drag; releasing it opens or toggles it.
    private var pressed: (index: Int, origin: NSPoint, release: PressRelease)?

    /// What releasing a press on an item does, if it wasn't dragged. Toggles wait for the
    /// release, so a drag carries the selection as it was when the press began.
    private enum PressRelease {
      case open
      case toggle
      case nothing
    }
    private let rubberBandLayer: CAShapeLayer = {
      let layer = CAShapeLayer()
      layer.fillColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
      layer.strokeColor = NSColor.selectedContentBackgroundColor.cgColor
      layer.lineWidth = 1
      layer.isHidden = true
      layer.zPosition = 10
      layer.actions = PhotoGridCellLayer.noActions
      return layer
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
      layer?.addSublayer(renderer.contentLayer)
      layer?.addSublayer(rubberBandLayer)
      // A reveal can come from a SwiftUI update, which mustn't change state itself.
      renderer.onReveal = { [weak self] in
        DispatchQueue.main.async { self?.reportShowingItems() }
      }
      setAccessibilityRole(.group)
      setAccessibilityLabel(String(localized: "Photos"))
      // The cells are layers, so the grid tells Siri itself which photos are where.
      appEntityUIElementProvider = { view, context in
        MainActor.assumeIsolated {
          guard let grid = view as? PhotoGridNSView else { return [] }
          return grid.renderer.siriElements(context, visible: grid.visibleRect)
        }
      }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(to scrollView: NSScrollView) {
      self.scrollView = scrollView
      let clip = scrollView.contentView
      clip.postsBoundsChangedNotifications = true
      scrollView.postsFrameChangedNotifications = true
      // Selector observers are dropped automatically when the view goes away.
      NotificationCenter.default.addObserver(
        self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification, object: clip)
      NotificationCenter.default.addObserver(
        self, selector: #selector(scrollFrameDidChange), name: NSView.frameDidChangeNotification, object: scrollView)
      // Only the user's scrolling moves the grid off its end; the clip also moves while the
      // window lays out.
      NotificationCenter.default.addObserver(
        self, selector: #selector(updatePinnedToEnd), name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    @objc private func updatePinnedToEnd() {
      guard startsAtEnd, !isKeepingEnd, let clip = scrollView?.contentView else { return }
      pinnedToEnd = clip.bounds.maxY >= frame.height - 2
      coordinator?.reportAtEnd(pinnedToEnd)
    }

    @objc private func clipBoundsDidChange() { didScroll() }

    @objc private func scrollFrameDidChange() {
      applyLayout()
      reportShowingItems()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      applyLayout()
    }

    func setDataSource(_ dataSource: any PhotoGridDataSource) {
      cancelRowGestures()
      let sameSource = renderer.dataSource === dataSource && dataSource.itemCount > 0
      let animates = sameSource && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let oldY = visibleRect.minY
      let previous = sameSource ? renderer.detachCells() : nil
      if !sameSource { renderer.tearDown() }
      renderer.dataSource = dataSource
      let anchor = pinnedToEnd ? nil : coordinator?.offsetPreservingCell(previous, visible: visibleRect, layout: makeLayout())
      applyLayout(populate: false, anchor: anchor)
      if let previous {
        renderer.reloadData(visibleRect: visibleRect, previous: previous, shift: visibleRect.minY - oldY, animated: animates)
      } else {
        renderer.reloadData(visibleRect: visibleRect)
      }
      coordinator?.reportTop(renderer.topIndex(atY: visibleRect.minY), reloaded: true)
      reportShowingItems()
    }

    private var hasShownItems = false

    /// Once, when items are first drawn: right away if their images were cached, else
    /// when the renderer reveals them.
    private func reportShowingItems() {
      guard !hasShownItems, renderer.hasPixels(in: visibleRect) else { return }
      hasShownItems = true
      // Layout can run inside a SwiftUI update, which mustn't change state itself.
      DispatchQueue.main.async { self.coordinator?.options.onShowItems?() }
    }

    /// What the scroll view shows, cells only: the gaps stay clear, so the image sits on
    /// whatever background is behind the grid. Nil while the cells wait for their images.
    func snapshotImage() -> CGImage? {
      guard renderer.hasPixels(in: visibleRect), !renderer.hasLockedPixels(in: visibleRect), let scrollView, let window else { return nil }
      let size = scrollView.bounds.size
      let scale = window.backingScaleFactor
      let width = Int((size.width * scale).rounded())
      let height = Int((size.height * scale).rounded())
      guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      let clip = scrollView.contentView
      context.scaleBy(x: scale, y: scale)
      // The grid is flipped: its first row is at the top.
      context.translateBy(x: 0, y: size.height)
      context.scaleBy(x: 1, y: -1)
      context.translateBy(x: clip.frame.minX - clip.bounds.minX, y: clip.frame.minY - clip.bounds.minY)
      renderer.contentLayer.render(in: context)
      return context.makeImage()
    }

    func scrollToEnd() {
      guard let clip = scrollView?.contentView else { return }
      let end = NSPoint(x: 0, y: max(0, frame.height - clip.bounds.height))
      guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
        clip.scroll(to: end)
        scrollView?.reflectScrolledClipView(clip)
        return
      }
      let runUp = clip.bounds.height * 3
      if end.y - clip.bounds.minY > runUp {
        clip.scroll(to: NSPoint(x: 0, y: end.y - runUp))
        scrollView?.reflectScrolledClipView(clip)
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.35
        context.allowsImplicitAnimation = true
        clip.animator().setBoundsOrigin(end)
      }
      pinnedToEnd = true
      coordinator?.reportAtEnd(true)
    }

    private var startsAtEnd: Bool { coordinator?.options.startsAtEnd == true }
    /// With `startsAtEnd`, whether the grid shows (and keeps showing) its last row.
    private var pinnedToEnd = true
    private var isKeepingEnd = false

    /// With `startsAtEnd`, keeps the grid's distance from its newest end through a change
    /// of size or items, so items added or removed above stay out of sight.
    private func keepingEnd(anchor: CGFloat? = nil, _ change: () -> Void) {
      guard startsAtEnd, let clip = scrollView?.contentView else { return change() }
      let fromEnd = pinnedToEnd ? 0 : max(0, frame.height - clip.bounds.maxY)
      isKeepingEnd = true
      change()
      let end = max(0, frame.height - clip.bounds.height)
      clip.scroll(to: NSPoint(x: 0, y: min(end, max(0, anchor ?? end - fromEnd))))
      scrollView?.reflectScrolledClipView(clip)
      isKeepingEnd = false
    }

    private var availableWidth: CGFloat { scrollView?.contentView.bounds.width ?? bounds.width }

    private func makeLayout() -> PhotoGridLayout {
      let steps = PhotoGridZoom.cellWidthSteps
      let target = steps[min(max(zoomStep, 0), steps.count - 1)]
      let width = availableWidth
      let columns = max(1, Int((width / target).rounded()))
      return PhotoGridLayout(
        columns: columns, spacing: target < 100 ? 1 : 2, width: width,
        itemCount: renderer.dataSource?.itemCount ?? 0, pixelScale: backingScale,
        alignsNewestRow: coordinator?.options.alignsNewestRow == true)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func applyLayout(populate: Bool = true, anchor: CGFloat? = nil) {
      guard !isChangingColumns else { return }
      renderer.displayScale = backingScale
      let layout = makeLayout()
      let height = max(layout.contentHeight, scrollView?.contentView.bounds.height ?? 0)
      isChangingColumns = true
      keepingEnd(anchor: anchor) { setFrameSize(NSSize(width: layout.width, height: height)) }
      isChangingColumns = false
      renderer.setLayout(layout, visibleRect: visibleRect, populate: populate)
    }

    private func didScroll() {
      // A column change moves the clip before the renderer has the new layout.
      guard !isChangingColumns else { return }
      let now = CACurrentMediaTime()
      let offset = visibleRect.minY
      let elapsed = now - lastScrollTime
      velocity = elapsed > 0 && elapsed < 0.2 ? (offset - lastOffset) / CGFloat(elapsed) : 0
      lastOffset = offset
      lastScrollTime = now
      renderer.update(visibleRect: visibleRect, velocity: velocity)
      updateHoverForScroll()
      coordinator?.reportTop(renderer.topIndex(atY: offset))
      settleWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.velocity = 0
          self.renderer.update(visibleRect: self.visibleRect, atRest: true)
        }
      }
      settleWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func setZoomStep(_ step: Int, anchor: (index: Int, viewportY: CGFloat)?) {
      let clamped = min(max(step, 0), PhotoGridZoom.cellWidthSteps.count - 1)
      guard clamped != zoomStep else { return }
      let rect = visibleRect
      let anchor =
        anchor ?? renderer.layout.indices(in: rect).first.map { ($0, renderer.layout.frame(at: $0).midY - rect.minY) }
      zoomStep = clamped
      guard let clip = scrollView?.contentView else {
        applyLayout()
        return
      }
      let layout = makeLayout()
      let oldY = clip.bounds.minY
      let height = max(layout.contentHeight, clip.bounds.height)
      let maxOffset = max(0, height - clip.bounds.height)
      var target = oldY
      if startsAtEnd, pinnedToEnd {
        // At the newest photos, zooming stays there.
        target = maxOffset
      } else if let anchor {
        target = min(maxOffset, layout.offsetKeeping(index: anchor.index, atViewportY: anchor.viewportY))
      }
      isChangingColumns = true
      setFrameSize(NSSize(width: layout.width, height: height))
      clip.scroll(to: NSPoint(x: 0, y: target))
      scrollView?.reflectScrolledClipView(clip)
      isChangingColumns = false
      renderer.setLayout(
        layout, visibleRect: visibleRect, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        shift: clip.bounds.minY - oldY)
      coordinator?.reportTop(renderer.topIndex(atY: visibleRect.minY))
      coordinator?.onZoom(clamped)
    }

    /// The grid follows the trackpad, as on iPhone: it scales live until the pinch reaches
    /// the next column count, then glides there.
    override func magnify(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if event.phase == .began {
        magnification = 0
        pinchPoint = point
      }
      magnification += event.magnification
      let anchorIndex = renderer.index(at: pinchPoint) ?? renderer.layout.indices(in: visibleRect).lowerBound
      let anchor = (anchorIndex, pinchPoint.y - visibleRect.minY)
      let densest = PhotoGridZoom.cellWidthSteps.count - 1
      if magnification > 0.25, zoomStep > 0 {
        let viewportY = point.y - visibleRect.minY
        setZoomStep(zoomStep - 1, anchor: anchor)
        magnification = 0
        pinchPoint = NSPoint(x: point.x, y: viewportY + visibleRect.minY)
      } else if magnification < -0.2, zoomStep < densest {
        let viewportY = point.y - visibleRect.minY
        setZoomStep(zoomStep + 1, anchor: anchor)
        magnification = 0
        pinchPoint = NSPoint(x: point.x, y: viewportY + visibleRect.minY)
      } else if event.phase != .ended, event.phase != .cancelled {
        let scale = 1 + magnification
        let atLimit = (scale > 1 && zoomStep == 0) || (scale < 1 && zoomStep == densest)
        renderer.setLiveScale(1 + (scale - 1) * (atLimit ? 0.2 : 0.5), about: pinchPoint, visibleRect: visibleRect)
      }
      if event.phase == .ended || event.phase == .cancelled {
        renderer.endLiveScale(
          visibleRect: visibleRect, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
      }
    }

    func scroll(to index: Int) {
      guard index >= 0, index < renderer.layout.itemCount, let clip = scrollView?.contentView else { return }
      let maxOffset = max(0, frame.height - clip.bounds.height)
      clip.scroll(to: NSPoint(x: 0, y: min(maxOffset, renderer.layout.frame(at: index).minY)))
      scrollView?.reflectScrolledClipView(clip)
      updatePinnedToEnd()
    }

    /// A plain click opens an item, as on iPhone and Google Photos for the web. ⌘-click,
    /// ⇧-click, a click on the circle in a cell's corner, or a drag across empty space
    /// selects; once anything is selected, a click adds or removes items until Escape.
    override func mouseDown(with event: NSEvent) {
      guard coordinator?.acceptsRowInput == true else { return }
      window?.makeFirstResponder(self)
      keyboardCursor = nil
      let point = convert(event.locationInWindow, from: nil)
      guard let index = renderer.index(at: point) else {
        // A drag from empty space draws a selection rectangle.
        let base = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) ? renderer.selection : []
        rubberBand = (point, base)
        updateSelection(base)
        return
      }
      let flags = event.modifierFlags
      let release: PressRelease
      if flags.contains(.shift), let anchor = selectionAnchor, !renderer.selection.isEmpty {
        // Extending a range only adds, so it can show at once.
        updateSelection(renderer.selection.union(min(anchor, index)...max(anchor, index)))
        release = .nothing
      } else if flags.contains(.command) || flags.contains(.shift) || isSelecting || hitsCheck(point, at: index) {
        release = .toggle
      } else {
        release = event.clickCount == 1 ? .open : .nothing
      }
      pressed = (index, point, release)
    }

    /// Selecting: something is selected, or the host is in a Select mode.
    private var isSelecting: Bool { !renderer.selection.isEmpty || coordinator?.options.isSelecting == true }

    private func hitsCheck(_ point: NSPoint, at index: Int) -> Bool {
      let frame = renderer.layout.frame(at: index)
      let check = PhotoGridCellLayer.checkRect(side: frame.width).offsetBy(dx: frame.minX, dy: frame.minY)
      return check.insetBy(dx: -6, dy: -6).contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
      guard coordinator?.acceptsRowInput == true else { return cancelRowGestures() }
      if let press = pressed {
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.origin.x, point.y - press.origin.y) > 4 else { return }
        pressed = nil
        beginFileDrag(event: event, from: press.index)
        return
      }
      guard let band = rubberBand else { return }
      autoscroll(with: event)
      let point = convert(event.locationInWindow, from: nil)
      let rect = NSRect(
        x: min(band.origin.x, point.x), y: min(band.origin.y, point.y),
        width: abs(point.x - band.origin.x), height: abs(point.y - band.origin.y))
      rubberBandLayer.isHidden = false
      rubberBandLayer.path = CGPath(rect: rect, transform: nil)
      let selection = band.base.union(renderer.indices(intersecting: rect))
      if selection != renderer.selection { updateSelection(selection) }
    }

    /// Drags the selection, or just the pressed item when it isn't part of it.
    private func beginFileDrag(event: NSEvent, from index: Int) {
      guard let provider = coordinator?.options.dragItem else { return }
      let dragged = renderer.selection.contains(index) ? renderer.selection.sorted() : [index]
      let items = dragged.enumerated().compactMap { offset, index -> NSDraggingItem? in
        guard let file = provider(index) else { return nil }
        let item = NSDraggingItem(pasteboardWriter: GridFilePromise.provider(for: file))
        // Every item goes; only the first few are drawn under the pointer.
        let contents = offset < 40 ? renderer.cellLayer(at: index)?.contents : nil
        item.setDraggingFrame(renderer.layout.frame(at: index), contents: contents)
        return item
      }
      guard !items.isEmpty else { return }
      beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
      guard coordinator?.acceptsRowInput == true else { return cancelRowGestures() }
      if let press = pressed {
        switch press.release {
        case .open:
          selectionAnchor = press.index
          coordinator?.onOpen(press.index)
        case .toggle:
          var selection = renderer.selection
          if selection.contains(press.index) { selection.remove(press.index) } else { selection.insert(press.index) }
          selectionAnchor = press.index
          updateSelection(selection)
        case .nothing:
          break
        }
      }
      clearPress()
    }

    private func cancelRowGestures() {
      selectionAnchor = nil
      keyboardCursor = nil
      clearPress()
    }

    private func clearPress() {
      pressed = nil
      rubberBand = nil
      rubberBandLayer.isHidden = true
      rubberBandLayer.path = nil
    }

    // MARK: Hover

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let hoverArea { removeTrackingArea(hoverArea) }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
      addTrackingArea(area)
      hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
      updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { renderer.hoveredIndex = nil }

    /// The pointer stays put while the grid scrolls under it.
    private func updateHoverForScroll() {
      guard renderer.hoveredIndex != nil || window?.isKeyWindow == true, let window else { return }
      let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      updateHover(at: visibleRect.contains(point) ? point : nil)
    }

    private func updateHover(at point: NSPoint?) {
      let index = point.flatMap { renderer.index(at: $0) }
      if renderer.hoveredIndex != index { renderer.hoveredIndex = index }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      guard let coordinator, coordinator.acceptsRowInput, let provider = coordinator.options.menu else { return nil }
      let point = convert(event.locationInWindow, from: nil)
      // A menu on an item outside the selection acts on that item alone, and leaves the
      // selection (and the grid out of selecting) as it was.
      guard let index = renderer.index(at: point) else { return nil }
      let items = provider(coordinator.menuTargets(for: index, selection: renderer.selection))
      guard !items.isEmpty else { return nil }
      let menu = NSMenu()
      for (_, group) in PhotoGridMenuItem.grouped(items) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in group { menu.addItem(Self.menuItem(item)) }
      }
      return menu
    }

    private static func menuItem(_ item: PhotoGridMenuItem) -> NSMenuItem {
      guard !item.children.isEmpty else { return ClosureMenuItem(item) }
      let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
      parent.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
      let submenu = NSMenu()
      for child in item.children { submenu.addItem(menuItem(child)) }
      parent.submenu = submenu
      return parent
    }

    override func keyDown(with event: NSEvent) {
      guard coordinator?.acceptsRowInput == true else { return }
      guard let dataSource = renderer.dataSource, dataSource.itemCount > 0 else { return super.keyDown(with: event) }
      let current = keyboardCursor ?? selectionAnchor ?? renderer.selection.min()
      let columns = renderer.layout.columns
      var next: Int?
      switch event.specialKey {
      case .leftArrow: next = (current ?? 1) - 1
      case .rightArrow: next = (current ?? -1) + 1
      case .upArrow: next = (current ?? columns) - columns
      case .downArrow: next = (current ?? -columns) + columns
      case .carriageReturn, .enter:
        if let current { coordinator?.onOpen(current) }
        return
      default:
        if event.keyCode == 53, !renderer.selection.isEmpty {
          updateSelection([])
          return
        }
        if event.charactersIgnoringModifiers == " ", let current {
          coordinator?.onOpen(current)
          return
        }
        return super.keyDown(with: event)
      }
      guard let target = next, target >= 0, target < dataSource.itemCount else { return }
      keyboardCursor = target
      if event.modifierFlags.contains(.shift), let anchor = selectionAnchor ?? current {
        selectionAnchor = anchor
        updateSelection(Set(min(anchor, target)...max(anchor, target)))
      } else {
        selectionAnchor = target
        updateSelection([target])
      }
      scrollToVisible(renderer.layout.frame(at: target).insetBy(dx: 0, dy: -8))
    }

    override func selectAll(_ sender: Any?) {
      guard coordinator?.acceptsRowInput == true else { return }
      guard let count = renderer.dataSource?.itemCount, count > 0 else { return }
      updateSelection(Set(0..<count))
    }

    private func updateSelection(_ selection: Set<Int>) {
      renderer.selection = selection
      renderer.showsSelectionCircles = isSelecting
      coordinator?.onSelect(selection)
    }

    override func accessibilityChildren() -> [Any]? {
      guard let dataSource = renderer.dataSource else { return [] }
      return renderer.layout.indices(in: visibleRect).map { index in
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.image)
        element.setAccessibilityLabel(dataSource.accessibilityLabel(at: index))
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(renderer.layout.frame(at: index))
        element.setAccessibilitySelected(renderer.selection.contains(index))
        return element
      }
    }
  }

  extension PhotoGridNSView: NSDraggingSource {
    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .outsideApplication ? .copy : []
    }
  }

  /// Writes one dragged item where it's dropped. Kept alive by its provider, which the
  /// drag holds until it's done; nothing here holds the provider, so both go with it.
  private final class GridFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let file: PhotoGridDragItem
    private static let queue: OperationQueue = {
      let queue = OperationQueue()
      queue.qualityOfService = .userInitiated
      queue.maxConcurrentOperationCount = 4
      return queue
    }()

    private init(_ file: PhotoGridDragItem) {
      self.file = file
      super.init()
    }

    static func provider(for file: PhotoGridDragItem) -> NSFilePromiseProvider {
      let promise = GridFilePromise(file)
      let type = file.isVideo ? UTType.movie : UTType.image
      // The delegate is weak; `userInfo` keeps the promise for as long as the provider.
      let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promise)
      provider.userInfo = promise
      return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
      file.fileName
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(
      _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
      let export = file.export
      let done = UncheckedSendableBox(completionHandler)
      Task.detached(priority: .userInitiated) {
        do {
          let source = try await export()
          try FileManager.default.copyItem(at: source, to: url)
          done.value(nil)
        } catch {
          done.value(error)
        }
      }
    }
  }

  private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
  }

  @MainActor
  private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ item: PhotoGridMenuItem) {
      handler = item.action
      super.init(title: item.title, action: #selector(runHandler), keyEquivalent: "")
      target = self
      image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runHandler() { handler() }
  }
#endif
