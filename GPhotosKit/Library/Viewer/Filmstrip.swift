#if os(iOS)
  import SwiftUI
  import UIKit

  /// The strip of thumbnails under a photo in the viewer, as in Photos: narrow slices, the
  /// one in the middle opened to its own shape. Scrubbing it changes the photo; paging the
  /// photo moves it. Draws only the visible slices, so it costs the same at any size.
  /// Connects the pager, the filmstrip and the scrub preview without going through
  /// SwiftUI state, which would re-render the viewer on every frame of a swipe or scrub.
  @MainActor
  final class FilmstripLink {
    fileprivate weak var strip: FilmstripView?
    fileprivate weak var preview: ScrubPreviewView?

    /// The pager's position in items while the user swipes (2.4 is 40% of the way from
    /// the third photo to the fourth): the strip moves with the finger, as in Photos.
    func pagerMoved(to position: CGFloat) { strip?.follow(position) }

    #if DEBUG
      func runStress(seconds: TimeInterval) { strip?.runStress(seconds: seconds) }
    #endif
  }

  struct Filmstrip: UIViewRepresentable {
    static let height = FilmstripView.height
    let source: any MediaViewerSource
    @Binding var index: Int?
    let link: FilmstripLink
    let thumbnailRevision: Int

    func makeUIView(context: Context) -> FilmstripView {
      let view = FilmstripView()
      view.source = source
      view.link = link
      link.strip = view
      view.onScrub = { index in scrub(to: index) }
      return view
    }

    func updateUIView(_ view: FilmstripView, context: Context) {
      view.onScrub = { index in scrub(to: index) }
      if view.source !== source { view.source = source }
      view.show(index ?? 0, count: source.itemCount, thumbnailRevision: thumbnailRevision)
    }

    /// Pages jump rather than slide while scrubbing.
    private func scrub(to newIndex: Int) {
      guard index != newIndex else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { index = newIndex }
    }

    static func dismantleUIView(_ view: FilmstripView, coordinator: ()) { view.tearDown() }
  }

  final class FilmstripView: UIScrollView, UIScrollViewDelegate {
    weak var source: (any MediaViewerSource)? {
      didSet { reload() }
    }
    weak var link: FilmstripLink?
    var onScrub: (Int) -> Void = { _ in }

    // Photos' measurements: narrow rounded slices with a clear gap between them.
    static let height: CGFloat = 30
    private static let sliceWidth: CGFloat = 20
    private static let spacing: CGFloat = 3
    /// Extra room on each side of the opened slice.
    private static let margin: CGFloat = 8
    private var pitch: CGFloat { Self.sliceWidth + Self.spacing }

    private var count = 0
    private var thumbnailRevision = 0
    private var shownIndex = -1
    private var slices: [Int: Slice] = [:]
    private var pool: [Slice] = []
    private var isScrubbing: Bool { isTracking || isDragging || isDecelerating || isStressing }
    private var isStressing = false

    #if DEBUG
      /// Scrubs across the strip at about 25 photos a second, through the same path as a
      /// finger, and logs frame times (`-UIScreen cloudFilmstripStress`).
      func runStress(seconds: TimeInterval) {
        isStressing = true
        _ = ScrollStress(name: "filmstrip", seconds: seconds) { [weak self] frame in
          guard let self else { return }
          self.contentOffset.x += self.pitch * 25 * frame
          self.layoutIfNeeded()
        }
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(seconds + 0.05))
          self?.isStressing = false
          self?.finishScrub()
        }
      }
    #endif
    private let feedback = UISelectionFeedbackGenerator()

    private final class Slice: CALayer {
      var itemID: String?
      var ticket: ThumbnailTicket?

      override init() {
        super.init()
        // Cropped with `contentsRect` rather than a mask, so each slice is one textured quad.
        contentsGravity = .resize
        backgroundColor = UIColor.secondarySystemFill.cgColor
        // A layer with only contents is rounded without an offscreen pass.
        cornerRadius = 4
        cornerCurve = .continuous
        masksToBounds = true
      }

      func setImage(_ image: CGImage?) {
        contents = image
        cropContents()
      }

      /// Fills the slice with the middle of the image, as aspect-fill would.
      func cropContents() {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, bounds.height > 0 else { return }
        let image = contents as! CGImage
        let imageRatio = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let sliceRatio = bounds.width / bounds.height
        contentsRect =
          imageRatio > sliceRatio
          ? CGRect(x: (1 - sliceRatio / imageRatio) / 2, y: 0, width: sliceRatio / imageRatio, height: 1)
          : CGRect(x: 0, y: (1 - imageRatio / sliceRatio) / 2, width: 1, height: imageRatio / sliceRatio)
      }

      override init(layer: Any) { super.init(layer: layer) }
      required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

      override func action(forKey event: String) -> (any CAAction)? { NSNull() }
    }

    override init(frame: CGRect) {
      super.init(frame: frame)
      delegate = self
      showsHorizontalScrollIndicator = false
      // The centering inset is the only one; a landscape safe area mustn't add to it.
      contentInsetAdjustmentBehavior = .never
      alwaysBounceHorizontal = true
      decelerationRate = .fast
      clipsToBounds = false
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
      isAccessibilityElement = true
      accessibilityLabel = String(localized: "Filmstrip")
      accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    func tearDown() {
      for (_, slice) in slices { slice.ticket?.cancel() }
    }

    /// Follows the viewer's page, unless the user is moving the strip.
    func show(_ index: Int, count: Int, thumbnailRevision: Int) {
      if count != self.count {
        self.count = count
        // The last slice's own width too, so the last photo can come to the middle.
        contentSize = CGSize(width: CGFloat(max(count - 1, 0)) * pitch + Self.sliceWidth, height: Self.height)
        reload()
      }
      if thumbnailRevision != self.thumbnailRevision {
        self.thumbnailRevision = thumbnailRevision
        reload()
      }
      guard index != shownIndex, !isScrubbing else { return }
      shownIndex = index
      let target = offset(for: index)
      // After a swipe the strip has followed the finger and is nearly there already.
      let near = abs(contentOffset.x - target) < pitch * 0.75
      let animated = !near && window != nil && !UIAccessibility.isReduceMotionEnabled
      setContentOffset(CGPoint(x: target, y: 0), animated: animated)
      if !animated { layoutSlices() }
    }

    /// Tracks a swipe between photos.
    func follow(_ position: CGFloat) {
      guard !isScrubbing, count > 0 else { return }
      let clamped = min(max(position, 0), CGFloat(count - 1))
      contentOffset.x = clamped * pitch - contentInset.left
    }

    private func reload() {
      for (_, slice) in slices { recycle(slice) }
      slices.removeAll()
      setNeedsLayout()
    }

    private func offset(for index: Int) -> CGFloat { CGFloat(index) * pitch - contentInset.left }

    private var laidOutSize: CGSize = .zero

    /// Scrolling lays the slices out from `scrollViewDidScroll`; this only handles a new size.
    override func layoutSubviews() {
      super.layoutSubviews()
      let inset = bounds.width / 2 - Self.sliceWidth / 2
      if contentInset.left != inset {
        contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if shownIndex >= 0 { contentOffset.x = offset(for: shownIndex) }
      }
      if bounds.size != laidOutSize || slices.isEmpty {
        laidOutSize = bounds.size
        layoutSlices()
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      layoutSlices()
      guard isScrubbing, count > 0, let source else { return }
      let index = centeredIndex
      guard index != shownIndex else { return }
      shownIndex = index
      // A tick per photo while scrubbing slowly; a fling would only buzz.
      if abs(panGestureRecognizer.velocity(in: self).x) < 600 {
        feedback.selectionChanged()
        feedback.prepare()
      }
      // The photo under the strip shows from cached images on every step; the viewer's
      // page (screen-sized image, zoom, Live Text) is built once, where the scrub stops.
      link?.preview?.show(
        id: source.itemID(at: index), source: source.thumbnailSource)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { feedback.prepare() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { finishScrub() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrub() }

    private func finishScrub() {
      onScrub(centeredIndex)
      link?.preview?.hideSoon()
    }

    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      // Comes to rest with a slice in the middle.
      let position = (targetContentOffset.pointee.x + contentInset.left) / pitch
      let index = min(max(Int(position.rounded()), 0), max(count - 1, 0))
      targetContentOffset.pointee.x = offset(for: index)
    }

    private var centeredIndex: Int {
      let position = (contentOffset.x + contentInset.left) / pitch
      return min(max(Int(position.rounded()), 0), max(count - 1, 0))
    }

    // VoiceOver: swipe up or down to move a photo at a time.
    override var accessibilityValue: String? {
      get { count > 0 ? String(localized: "\(shownIndex + 1) of \(count)") : nil }
      set {}
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ delta: Int) {
      let index = min(max(shownIndex + delta, 0), max(count - 1, 0))
      guard index != shownIndex else { return }
      shownIndex = index
      setContentOffset(CGPoint(x: offset(for: index), y: 0), animated: !UIAccessibility.isReduceMotionEnabled)
      onScrub(index)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      let x = recognizer.location(in: self).x
      guard let (index, _) = slices.min(by: { abs($0.value.frame.midX - x) < abs($1.value.frame.midX - x) }) else { return }
      shownIndex = index
      setContentOffset(CGPoint(x: offset(for: index), y: 0), animated: !UIAccessibility.isReduceMotionEnabled)
      onScrub(index)
    }

    /// Slices are laid out on a regular pitch; the one nearest the middle opens to its
    /// shape and pushes its neighbours aside, smoothly as the strip moves.
    private func layoutSlices() {
      guard let source, count > 0, bounds.width > 0 else { return }
      let center = (contentOffset.x + contentInset.left) / pitch
      let first = max(0, Int(((contentOffset.x - 80) / pitch).rounded(.down)))
      let last = min(count - 1, Int(((contentOffset.x + bounds.width + 80) / pitch).rounded(.up)))
      guard first <= last else { return }
      // At most two slices are opening (the one leaving the middle and the one arriving).
      let lower = Int(center.rounded(.down))
      let upper = lower + 1
      let lowerGrowth = growth(of: lower, center: center, source: source)
      let upperGrowth = growth(of: upper, center: center, source: source)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for (index, slice) in slices where index < first || index > last {
        slices[index] = nil
        recycle(slice)
      }
      for index in first...last {
        let slice = slices[index] ?? dequeue(for: index, source: source)
        slices[index] = slice
        var shift: CGFloat = 0
        if index != lower { shift += lower < index ? lowerGrowth.extra / 2 : -lowerGrowth.extra / 2 }
        if index != upper { shift += upper < index ? upperGrowth.extra / 2 : -upperGrowth.extra / 2 }
        let width = index == lower ? lowerGrowth.width : index == upper ? upperGrowth.width : Self.sliceWidth
        let midX = CGFloat(index) * pitch + Self.sliceWidth / 2 + shift
        let frame = CGRect(x: midX - width / 2, y: 0, width: width, height: Self.height)
        if slice.frame != frame {
          slice.frame = frame
          slice.cropContents()
        }
      }
      CATransaction.commit()
    }

    private func growth(of index: Int, center: CGFloat, source: any MediaViewerSource) -> (extra: CGFloat, width: CGFloat) {
      guard index >= 0, index < count else { return (0, Self.sliceWidth) }
      let amount = max(0, 1 - abs(CGFloat(index) - center))
      guard amount > 0 else { return (0, Self.sliceWidth) }
      let ratio = min(max(source.aspectRatio(at: index) ?? 1, 0.5), 2)
      let width = Self.sliceWidth + (Self.height * ratio - Self.sliceWidth) * amount
      return (width - Self.sliceWidth + 2 * Self.margin * amount, width)
    }

    private func dequeue(for index: Int, source: any MediaViewerSource) -> Slice {
      let slice = pool.popLast() ?? Slice()
      if slice.superlayer == nil { layer.addSublayer(slice) }
      slice.isHidden = false
      let id = source.itemID(at: index)
      slice.itemID = id
      // Sharp enough for the opened slice; a fling only takes what's quick.
      let key = ThumbnailKey(id: id, bucket: .small)
      let cached = ThumbnailPipeline.shared.placeholder(for: key)
      slice.setImage(cached)
      // Anything already in memory that's big enough will do: a scrub passing hundreds of
      // photos mustn't start a request (for Google items, a download) for each.
      if (cached?.width ?? 0) < 96 {
        let fast = abs(panGestureRecognizer.velocity(in: self).x) > 2500
        slice.ticket = ThumbnailPipeline.shared.load(key, from: source.thumbnailSource, quality: fast ? .fast : .thumbnail) {
          [weak slice] image, _ in
          guard let slice, slice.itemID == id else { return }
          slice.setImage(image)
        }
      }
      return slice
    }

    private func recycle(_ slice: Slice) {
      slice.ticket?.cancel()
      slice.ticket = nil
      slice.itemID = nil
      slice.contents = nil
      slice.isHidden = true
      pool.append(slice)
    }
  }

  /// The photo under the filmstrip while scrubbing, drawn from cached images on every step.
  struct ScrubPreview: UIViewRepresentable {
    let link: FilmstripLink

    func makeUIView(context: Context) -> ScrubPreviewView {
      let view = ScrubPreviewView()
      link.preview = view
      return view
    }

    func updateUIView(_ view: ScrubPreviewView, context: Context) {}
  }

  final class ScrubPreviewView: UIView {
    private let imageLayer = CALayer()
    private var shownID: String?
    private var token: ImageRequestToken?
    private var detailTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isHidden = true
      backgroundColor = .systemBackground
      imageLayer.contentsGravity = .resizeAspect
      imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
      layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
      super.layoutSubviews()
      imageLayer.frame = bounds
    }

    func show(id: String, source: any ThumbnailSource) {
      hideTask?.cancel()
      alpha = 1
      guard id != shownID else { return }
      shownID = id
      token?.cancel()
      let preview = ThumbnailPipeline.shared.viewerPreview(for: id)
      imageLayer.contents = preview
      isHidden = preview == nil
      // Only for a photo the scrub rests on: passing photos would each start a download.
      detailTask?.cancel()
      detailTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard let self, !Task.isCancelled, self.shownID == id else { return }
        let scale = self.window?.screen.scale ?? 3
        let pixels = CGSize(width: self.bounds.width * scale, height: self.bounds.height * scale)
        self.token = source.requestImage(id: id, pixelSize: pixels, quality: .display) { [weak self] image, _ in
          Task { @MainActor in
            guard let self, self.shownID == id else { return }
            ThumbnailPipeline.shared.rememberViewerPreview(image, for: id)
            self.imageLayer.contents = image
            self.isHidden = false
          }
        }
      }
    }

    /// Once the scrub stops the real page takes over; the preview fades after it has drawn.
    func hideSoon() {
      hideTask?.cancel()
      hideTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard let self, !Task.isCancelled else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
          self.alpha = 0
        } completion: { _ in
          // Shown again meanwhile.
          guard self.alpha == 0 else { return }
          self.isHidden = true
          self.shownID = nil
          self.token?.cancel()
          self.imageLayer.contents = nil
        }
      }
    }
  }

#endif
