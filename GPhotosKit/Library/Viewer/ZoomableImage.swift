import AVFoundation
import Combine
import CoreGraphics
import SwiftUI
import VisionKit

/// Live Text, Visual Look Up and subject lifting for the photo on screen. One analyzer
/// serves every page; only the current page is analyzed, after it settles.
@MainActor
enum LiveTextAnalyzer {
  static let analyzer = ImageAnalyzer()
  static var isSupported: Bool { ImageAnalyzer.isSupported }

  static func analyze(_ image: CGImage) async -> ImageAnalysis? {
    guard isSupported else { return nil }
    let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
    return try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
  }
}

enum AspectFit {
  static func orientedSize(decoded: CGSize, metadata: CGSize) -> CGSize {
    guard decoded.width > 0, decoded.height > 0 else {
      return metadata.width > 0 && metadata.height > 0 ? metadata : .zero
    }
    let edge = max(metadata.width, metadata.height, decoded.width, decoded.height)
    let scale = edge / max(decoded.width, decoded.height)
    return CGSize(width: decoded.width * scale, height: decoded.height * scale)
  }

  static func uprightSize(_ size: CGSize, exifOrientation: Int) -> CGSize {
    (5...8).contains(exifOrientation) ? CGSize(width: size.height, height: size.width) : size
  }

  static func uprightSize(_ size: CGSize, videoTransform: CGAffineTransform) -> CGSize {
    CGRect(origin: .zero, size: size).applying(videoTransform).size
  }

  /// The largest size with `content`'s aspect ratio that fits in `container`.
  static func size(for content: CGSize, in container: CGSize) -> CGSize {
    guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return container }
    let scale = min(container.width / content.width, container.height / content.height)
    return CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
  }
}

/// A photo fitted to its page with native pinch, pan and double-tap zoom (`UIScrollView`
/// on iOS, `NSScrollView` magnification on the Mac). `pixelSize` is the asset's full size;
/// it sets the aspect ratio before any image arrives and how far zooming may go.
struct ZoomableImage: View {
  let image: CGImage?
  let pixelSize: CGSize
  var previewIdentity: ThumbnailIdentity?
  var isCurrent = false
  var showsProgress = true
  /// A sharper image is on its way.
  var isLoading = false
  /// The request ended with nothing to show.
  var didFail = false
  /// A video that can't play on yet.
  var isBuffering = false
  /// Offers Live Text on the image once it's on screen and settled.
  var liveText = false
  var onZoom: (CGFloat) -> Void = { _ in }
  var onTap: () -> Void = {}
  /// Swipe down at 1x.
  var onDismiss: () -> Void = {}
  /// Swipe up at 1x.
  var onSwipeUp: () -> Void = {}
  /// A video drawn over the image once it has a frame, zooming and moving with it.
  var player: AVPlayer?
  @Environment(\.viewerZoom) private var zoom
  @Environment(\.viewerItemID) private var itemID
  @Environment(\.viewerThumbnailIdentity) private var thumbnailIdentity
  @Environment(\.viewerNeighbors) private var neighbors
  #if os(iOS)
    @Environment(\.filmstripLink) private var filmstripLink
    @State private var firstFrame: CGImage?
  #endif
  @State private var videoSize = CGSize.zero

  var body: some View {
    // The pager can build a neighbour before its prefetch has delivered.
    let _ = neighbors?.revision
    let cacheIdentity = previewIdentity ?? thumbnailIdentity
    #if os(iOS)
      let handoff = filmstripLink?.handoffImage(for: itemID)
      let slice = handoff ?? firstFrame
    #else
      let slice: CGImage? = nil
    #endif
    let firstPreview =
      ViewerImage.preview(for: cacheIdentity, pixels: pixelSize, slice: slice)
      ?? (cacheIdentity == thumbnailIdentity ? nil : ViewerImage.preview(for: thumbnailIdentity, pixels: pixelSize))
    let preview = firstPreview?.image
    let previewIsCropped = firstPreview?.cropped == true
    let sharper = image.flatMap { image in
      previewIsCropped || ViewerImage.accepts(image, over: preview, isFinal: true) ? image : nil
    }
    let displayed = sharper ?? preview
    let decoded = displayed.map(ViewerImage.size) ?? .zero
    let cropped = sharper == nil && previewIsCropped
    let size = AspectFit.orientedSize(
      decoded: videoSize == .zero ? (cropped ? pixelSize : decoded) : videoSize, metadata: pixelSize)
    ZoomableImageRepresentable(
      image: displayed, pixelSize: size, cropped: cropped, liveText: liveText, onZoom: onZoom, onTap: onTap,
      onDismiss: onDismiss, onSwipeUp: onSwipeUp, player: player,
      onPull: zoom.map { zoom in
        { pull, frame in
          zoom.pull = pull
          zoom.pulledFrame = frame
        }
      }
    )
    .overlay {
      if didFail, displayed == nil, isCurrent, player == nil {
        Label("Couldn't Load", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      }
    }
    .overlay {
      ViewerLoadingIndicator(
        isLoading: isCurrent && showsProgress
          && (isBuffering || (player == nil && isLoading)))
    }
    #if os(iOS)
      .onChange(of: handoff, initial: true) {
        if let handoff { firstFrame = handoff }
      }
      .onChange(of: isCurrent && displayed != nil ? itemID : nil, initial: true) { _, readyID in
        guard let readyID else { return }
        // Let the native image view finish this update before taking down the scrub overlay.
        DispatchQueue.main.async { filmstripLink?.pageImageReady(readyID) }
      }
    #endif
    .onReceive(presentationSize.removeDuplicates().receive(on: DispatchQueue.main)) { videoSize = $0 }
  }

  private var presentationSize: AnyPublisher<CGSize, Never> {
    guard let item = player?.currentItem else { return Just(.zero).eraseToAnyPublisher() }
    return item.publisher(for: \.presentationSize).eraseToAnyPublisher()
  }
}

extension EnvironmentValues {
  @Entry var viewerItemID = ""
  @Entry var viewerThumbnailIdentity = ThumbnailIdentity(id: "")
  @Entry var viewerNeighbors: ViewerNeighborRequests?
  #if os(iOS)
    @Entry var filmstripLink: FilmstripLink?
  #endif
}

#if os(iOS)
  import UIKit

  private struct ZoomableImageRepresentable: UIViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let cropped: Bool
    let liveText: Bool
    let onZoom: (CGFloat) -> Void
    let onTap: () -> Void
    let onDismiss: () -> Void
    let onSwipeUp: () -> Void
    let player: AVPlayer?
    let onPull: ((CGFloat, CGRect?) -> Void)?

    func makeUIView(context: Context) -> ZoomingImageScrollView { ZoomingImageScrollView() }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
      view.setPlayer(player)
      view.onPull = onPull
      view.onZoom = onZoom
      view.onTap = onTap
      view.onDismiss = onDismiss
      view.onSwipeUp = onSwipeUp
      view.setContent(image: image, pixelSize: pixelSize, cropped: cropped)
      view.setLiveText(liveText && !cropped)
    }
  }

  /// The video over the still: hidden until it has a frame, so the still shows meanwhile.
  private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var readyObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
      super.init(frame: frame)
      playerLayer.videoGravity = .resizeAspect
      isHidden = true
      readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
        let ready = layer.isReadyForDisplay
        DispatchQueue.main.async { self?.isHidden = !ready }
      }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  }

  final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var liveTextEnabled = false
    private var analysisTask: Task<Void, Never>?
    private lazy var analysisInteraction: ImageAnalysisInteraction = {
      let interaction = ImageAnalysisInteraction()
      interaction.preferredInteractionTypes = .automatic
      imageView.addInteraction(interaction)
      imageView.isUserInteractionEnabled = true
      return interaction
    }()
    private var pixelSize: CGSize = .zero
    private var fittedForBounds: CGSize = .zero
    private weak var currentImage: CGImage?
    var onZoom: (CGFloat) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onSwipeUp: () -> Void = {}
    /// How far the photo is pulled down at 1x, and where it is in the window, as it moves.
    var onPull: ((CGFloat, CGRect?) -> Void)?
    private var lastPull: CGFloat = 0
    /// The finger's travel since a pull down began, which the photo follows 1:1.
    private var pullTranslation: CGPoint?
    private var pullStart: CGPoint?
    /// Room the viewer's header and toolbar take, kept clear for the Live Text button.
    static let chromeInsets = UIEdgeInsets(top: 96, left: 0, bottom: 92, right: 0)
    /// Two fingers are down, or came down during this touch. Zooming drives the image
    /// view's transform, so a pull down must never run at the same time.
    private var isPinching = false
    private var isAtRestZoom: Bool { zoomScale <= minimumZoomScale + 0.01 }

    override init(frame: CGRect) {
      super.init(frame: frame)
      delegate = self
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      contentInsetAdjustmentBehavior = .never
      decelerationRate = .fast
      // Vertical bounce at 1x carries swipe down to close and swipe up for details.
      alwaysBounceVertical = true
      isDirectionalLockEnabled = true
      imageView.contentMode = .scaleAspectFit
      imageView.clipsToBounds = true
      imageView.accessibilityIgnoresInvertColors = true
      addSubview(imageView)
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
      doubleTap.numberOfTapsRequired = 2
      addGestureRecognizer(doubleTap)
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      tap.require(toFail: doubleTap)
      addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContent(image: CGImage?, pixelSize: CGSize, cropped: Bool = false) {
      imageView.contentMode = cropped ? .scaleAspectFill : .scaleAspectFit
      if image !== currentImage {
        currentImage = image
        imageView.image = image.map { UIImage(cgImage: $0) }
        scheduleAnalysis()
      }
      let size = pixelSize.width > 0 ? pixelSize : image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
      if size != self.pixelSize {
        let previous = self.pixelSize
        self.pixelSize = size
        if previous.height <= 0 || size.height <= 0 || abs(previous.width / previous.height - size.width / size.height) > 0.01 {
          fit()
        }
      }
    }

    func setLiveText(_ enabled: Bool) {
      guard enabled != liveTextEnabled else { return }
      liveTextEnabled = enabled
      scheduleAnalysis()
    }

    private func scheduleAnalysis() {
      analysisTask?.cancel()
      guard liveTextEnabled, LiveTextAnalyzer.isSupported, let image = currentImage else {
        if LiveTextAnalyzer.isSupported, !liveTextEnabled { analysisInteraction.analysis = nil }
        return
      }
      analysisTask = Task { [weak self] in
        // Paging past a photo shouldn't analyze it.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, let analysis = await LiveTextAnalyzer.analyze(image), !Task.isCancelled else { return }
        self?.analysisInteraction.analysis = analysis
        self?.updateLiveTextInsets()
      }
    }

    /// Keeps the Live Text button (bottom right of the photo) out from under the header
    /// and toolbar when the photo reaches the screen's edges.
    private func updateLiveTextInsets() {
      guard liveTextEnabled, LiveTextAnalyzer.isSupported, zoomScale > 0 else { return }
      let onScreen = imageView.frame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
      let top = max(0, Self.chromeInsets.top - onScreen.minY) / zoomScale
      let bottom = max(0, onScreen.maxY - (bounds.height - Self.chromeInsets.bottom)) / zoomScale
      let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
      if analysisInteraction.supplementaryInterfaceContentInsets != insets {
        analysisInteraction.supplementaryInterfaceContentInsets = insets
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      if bounds.size != fittedForBounds { fit() }
      updateLiveTextInsets()
    }

    private var videoView: PlayerLayerView?

    func setPlayer(_ player: AVPlayer?) {
      guard player !== videoView?.playerLayer.player else { return }
      videoView?.removeFromSuperview()
      videoView = nil
      guard let player else { return }
      let view = PlayerLayerView(frame: imageView.bounds)
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.isUserInteractionEnabled = false
      view.playerLayer.player = player
      imageView.addSubview(view)
      videoView = view
    }

    private func fit() {
      guard bounds.width > 0, bounds.height > 0 else { return }
      fittedForBounds = bounds.size
      zoomScale = 1
      let fitted = AspectFit.size(for: pixelSize, in: bounds.size)
      imageView.transform = .identity
      imageView.frame = CGRect(origin: .zero, size: fitted)
      contentSize = fitted
      let screenScale = traitCollection.displayScale
      // Zoom to at least 1:1 pixels and at least 4x the fitted size.
      let pixelZoom = fitted.width > 0 ? pixelSize.width / (fitted.width * screenScale) : 1
      minimumZoomScale = 1
      maximumZoomScale = min(max(4, pixelZoom * 1.5), 16)
      center()
      contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private func center() {
      let horizontal = max(0, (bounds.width - contentSize.width) / 2)
      let vertical = max(0, (bounds.height - contentSize.height) / 2)
      contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      center()
      alwaysBounceVertical = zoomScale <= minimumZoomScale
    }

    /// As in Photos, a photo pulled down follows the finger both ways and shrinks the
    /// further it goes, instead of only sliding down with the scroll view's damped bounce.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard let onPull, !isPinching, !isZooming, !isZoomBouncing, panGestureRecognizer.numberOfTouches < 2 else { return }
      let bounce = zoomScale <= minimumZoomScale + 0.01 ? -(contentOffset.y + contentInset.top) : 0
      if isTracking, bounce > 0 || pullTranslation != nil {
        // The finger in the window: the pan's own translation ignores sideways movement
        // in a view that can't scroll sideways.
        let finger = panGestureRecognizer.location(in: nil)
        if pullStart == nil {
          let travel = panGestureRecognizer.translation(in: self)
          pullStart = CGPoint(x: finger.x - travel.x, y: finger.y - travel.y)
        }
        let start = pullStart ?? finger
        let translation = CGPoint(x: finger.x - start.x, y: finger.y - start.y)
        pullTranslation = translation
        let down = max(0, translation.y)
        let scale = max(0.6, 1 - down / (bounds.height * 1.4))
        // The scroll view already moved the photo by `bounce`; the transform adds the rest.
        imageView.transform = CGAffineTransform(translationX: translation.x, y: down - max(0, bounce))
          .scaledBy(x: scale, y: scale)
        lastPull = down
        onPull(down, imageView.convert(imageView.bounds, to: nil))
        return
      }
      guard pullTranslation == nil else { return }
      let pull = max(0, bounce)
      guard pull != lastPull else { return }
      lastPull = pull
      onPull(pull, nil)
    }

    /// A pull that didn't close springs back to the middle.
    private func endPull() {
      pullStart = nil
      guard pullTranslation != nil else { return }
      pullTranslation = nil
      lastPull = 0
      onPull?(0, nil)
      UIView.animate(
        springDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.35, bounce: 0, initialSpringVelocity: 0
      ) {
        imageView.transform = .identity
      }
    }

    /// A second finger during a pull: the photo goes back as it was and the pinch takes
    /// over, from the image view's own transform.
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
      isPinching = true
      pullStart = nil
      guard pullTranslation != nil else { return }
      pullTranslation = nil
      lastPull = 0
      imageView.transform = .identity
      onPull?(0, nil)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      // With a drag still running, the pinch lasts until `scrollViewDidEndDragging`.
      if !isDragging { isPinching = false }
      onZoom(scale)
      guard scale <= minimumZoomScale + 0.01 else { return }
      settle()
    }

    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      guard !isPinching, zoomScale <= minimumZoomScale + 0.01 else { return }
      // Negative when the photo is pulled down, positive when pushed up.
      let pull = contentOffset.y + contentInset.top
      if let pulled = pullTranslation {
        // Measured by the finger, which the photo follows.
        if pulled.y > 110 || (velocity.y < -0.6 && pulled.y > 30) {
          // The viewer takes the photo from where it is; it stays put meanwhile.
          targetContentOffset.pointee = contentOffset
          pullStart = nil
          pullTranslation = nil
          onDismiss()
        } else {
          endPull()
        }
      } else if pull > 60 || (velocity.y > 1 && pull > 20) {
        // Back to rest as the info sheet comes up; the sheet would otherwise stop the
        // bounce and leave the photo pushed up, throwing off the next swipe.
        targetContentOffset.pointee.y = -contentInset.top
        onSwipeUp()
        DispatchQueue.main.async { [weak self] in self?.settleVertically() }
      }
    }

    /// A pull the system cancelled (an incoming call, a system gesture) never reaches
    /// `scrollViewWillEndDragging`; it springs back here.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if pullTranslation != nil { endPull() }
      if isPinching, !isZooming, !isZoomBouncing {
        isPinching = false
        settle()
      }
    }

    private func settleVertically() {
      guard zoomScale <= minimumZoomScale + 0.01, contentOffset.y != -contentInset.top else { return }
      setContentOffset(CGPoint(x: contentOffset.x, y: -contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Back in the middle after a pinch, which can leave the photo off to one side.
    private func settle() {
      guard isAtRestZoom else { return }
      let rest = CGPoint(x: -contentInset.left, y: -contentInset.top)
      guard contentOffset != rest else { return }
      setContentOffset(rest, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Whatever stopped it (a sheet coming up), the photo at 1x comes back to rest.
    override func didMoveToWindow() {
      super.didMoveToWindow()
      settleVertically()
    }

    @objc private func handleTap() { onTap() }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      if zoomScale > minimumZoomScale + 0.01 {
        setZoomScale(minimumZoomScale, animated: true)
        return
      }
      let point = recognizer.location(in: imageView)
      let scale = min(maximumZoomScale, 2.5)
      let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
      zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
  }

#else
  import AppKit

  enum ViewerKeyboardAction: UInt16 {
    case previous = 123
    case next = 124
    case escape = 53
    case space = 49
  }

  final class ViewerKeyboardView: NSView {
    var onAction: ((ViewerKeyboardAction) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated {
          guard let self, event.window === self.window else { return false }
          return self.route(event, firstResponder: self.window?.firstResponder)
        }
        return handled ? nil : event
      }
    }

    func route(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
      guard !(firstResponder is NSText),
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
        let action = ViewerKeyboardAction(rawValue: event.keyCode), let onAction
      else { return false }
      onAction(action)
      return true
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }

  /// Scoped to this viewer's window; text fields keep their editing keys.
  struct ViewerKeyboardEvents: NSViewRepresentable {
    let onAction: (ViewerKeyboardAction) -> Void
    func makeNSView(context: Context) -> ViewerKeyboardView { ViewerKeyboardView() }
    func updateNSView(_ view: ViewerKeyboardView, context: Context) { view.onAction = onAction }
    static func dismantleNSView(_ view: ViewerKeyboardView, coordinator: ()) { view.stop() }
  }

  private struct ZoomableImageRepresentable: NSViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let cropped: Bool
    let liveText: Bool
    let onZoom: (CGFloat) -> Void
    let onTap: () -> Void
    let onDismiss: () -> Void
    let onSwipeUp: () -> Void
    let player: AVPlayer?
    let onPull: ((CGFloat, CGRect?) -> Void)?

    func makeNSView(context: Context) -> ZoomingImageScrollView { ZoomingImageScrollView() }

    func updateNSView(_ view: ZoomingImageScrollView, context: Context) {
      view.setPlayer(player)
      view.onZoom = onZoom
      view.setContent(image: image, pixelSize: pixelSize, cropped: cropped)
      view.setLiveText(liveText && !cropped)
    }
  }

  /// Keeps a document smaller than the viewport in the middle of it.
  private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      var rect = super.constrainBoundsRect(proposedBounds)
      guard let document = documentView else { return rect }
      let size = document.frame.size
      if size.width < rect.width { rect.origin.x = (size.width - rect.width) / 2 }
      if size.height < rect.height { rect.origin.y = (size.height - rect.height) / 2 }
      return rect
    }
  }

  private final class ImageLayerView: NSView {
    var onDoubleClick: (NSPoint) -> Void = { _ in }

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
      layer?.contentsGravity = .resizeAspect
      layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 { onDoubleClick(convert(event.locationInWindow, from: nil)) }
    }
  }

  /// The video over the still: hidden until it has a frame, so the still shows meanwhile.
  private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer = playerLayer
      playerLayer.videoGravity = .resizeAspect
      isHidden = true
      readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
        let ready = layer.isReadyForDisplay
        DispatchQueue.main.async { self?.isHidden = !ready }
      }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicks go to the image below, for double-click zoom.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  final class ZoomingImageScrollView: NSScrollView {
    private let imageView = ImageLayerView()
    private var liveTextEnabled = false
    private var analysisTask: Task<Void, Never>?
    private lazy var overlay: ImageAnalysisOverlayView = {
      let overlay = ImageAnalysisOverlayView()
      overlay.preferredInteractionTypes = .automatic
      overlay.frame = imageView.bounds
      overlay.autoresizingMask = [.width, .height]
      imageView.addSubview(overlay)
      return overlay
    }()
    private var pixelSize: CGSize = .zero
    private var fittedForSize: CGSize = .zero
    private weak var currentImage: CGImage?
    var onZoom: (CGFloat) -> Void = { _ in }

    override init(frame: NSRect) {
      super.init(frame: frame)
      contentView = CenteringClipView()
      drawsBackground = false
      hasVerticalScroller = false
      hasHorizontalScroller = false
      allowsMagnification = true
      minMagnification = 1
      documentView = imageView
      imageView.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
      NotificationCenter.default.addObserver(
        self, selector: #selector(didEndMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContent(image: CGImage?, pixelSize: CGSize, cropped: Bool = false) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      imageView.layer?.contentsGravity = cropped ? .resizeAspectFill : .resizeAspect
      imageView.layer?.masksToBounds = cropped
      defer { CATransaction.commit() }
      if image !== currentImage {
        currentImage = image
        imageView.layer?.contents = image
        scheduleAnalysis()
      }
      let size = pixelSize.width > 0 ? pixelSize : image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
      if size != self.pixelSize {
        let previous = self.pixelSize
        self.pixelSize = size
        if previous.height <= 0 || size.height <= 0 || abs(previous.width / previous.height - size.width / size.height) > 0.01 {
          fit()
        }
      }
    }

    override func layout() {
      super.layout()
      if bounds.size != fittedForSize { fit() }
    }

    private var videoView: PlayerLayerView?

    func setPlayer(_ player: AVPlayer?) {
      guard player !== videoView?.playerLayer.player else { return }
      videoView?.removeFromSuperview()
      videoView = nil
      guard let player else { return }
      let view = PlayerLayerView(frame: imageView.bounds)
      view.autoresizingMask = [.width, .height]
      view.playerLayer.player = player
      imageView.addSubview(view)
      videoView = view
    }

    func setLiveText(_ enabled: Bool) {
      guard enabled != liveTextEnabled else { return }
      liveTextEnabled = enabled
      scheduleAnalysis()
    }

    private func scheduleAnalysis() {
      analysisTask?.cancel()
      guard liveTextEnabled, LiveTextAnalyzer.isSupported, let image = currentImage else {
        if LiveTextAnalyzer.isSupported, !liveTextEnabled { overlay.analysis = nil }
        return
      }
      analysisTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, let analysis = await LiveTextAnalyzer.analyze(image), !Task.isCancelled else { return }
        self?.overlay.analysis = analysis
      }
    }

    private func fit() {
      guard bounds.width > 0, bounds.height > 0 else { return }
      fittedForSize = bounds.size
      magnification = 1
      imageView.frame = NSRect(origin: .zero, size: AspectFit.size(for: pixelSize, in: bounds.size))
      let scale = window?.backingScaleFactor ?? 2
      let pixelZoom = imageView.frame.width > 0 ? pixelSize.width / (imageView.frame.width * scale) : 1
      maxMagnification = min(max(4, pixelZoom * 1.5), 16)
    }

    private func toggleZoom(at point: NSPoint) {
      let target: CGFloat = magnification > 1.01 ? 1 : min(maxMagnification, 2.5)
      animator().setMagnification(target, centeredAt: point)
      onZoom(target)
    }

    @objc private func didEndMagnify() { onZoom(magnification) }

    // At 1x, swipes page between photos in the enclosing scroll view.
    override func scrollWheel(with event: NSEvent) {
      if magnification <= 1.01 {
        nextResponder?.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }
  }
#endif
