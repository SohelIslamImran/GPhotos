#if os(iOS)
  import SwiftUI
  import UIKit

  /// The strip of thumbnails under a photo in the viewer, as in Photos: narrow slices, the
  /// one in the middle opened to its own shape. Scrubbing it changes the photo; paging the
  /// photo moves it. Draws only the visible slices, so it costs the same at any size.
  /// Connects the pager, the filmstrip and the scrub preview without going through
  /// SwiftUI state, which would re-render the viewer on every frame of a swipe or scrub.
  @MainActor
  @Observable
  final class FilmstripLink {
    @ObservationIgnored fileprivate weak var strip: FilmstripView?
    @ObservationIgnored fileprivate weak var preview: ScrubPreviewView?
    @ObservationIgnored fileprivate var readyID: String?
    /// The item under the strip's middle during a scrub, for the title only.
    private(set) var scrubbedIndex: Int?
    private(set) var isMoving = false
    @ObservationIgnored private var lastTitleTime: CFTimeInterval = 0
    @ObservationIgnored private var pendingTitle: Task<Void, Never>?

    fileprivate func scrubbed(to index: Int?) {
      if isMoving != (index != nil) { isMoving = index != nil }
      pendingTitle?.cancel()
      pendingTitle = nil
      let now = CACurrentMediaTime()
      // A few times a second reads as live and leaves the frames to the strip.
      if index != nil, now - lastTitleTime < 0.1 {
        pendingTitle = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(100))
          if !Task.isCancelled { self?.scrubbed(to: index) }
        }
        return
      }
      lastTitleTime = now
      if scrubbedIndex != index { scrubbedIndex = index }
    }

    var isScrubbing: Bool { strip?.isScrubbing == true || strip?.isTracking == true }

    func pageImageReady(_ id: String) {
      readyID = id
      preview?.pageImageReady(id)
    }

    func handoffImage(for id: String) -> CGImage? { preview?.handoffImage(for: id) }

    /// A swipe on the photo takes over from a strip still coming to rest.
    func pagerTouched() { strip?.interruptFling() }

    /// The pager's position in items while the user swipes (2.4 is 40% of the way from
    /// the third photo to the fourth): the strip moves with the finger, as in Photos.
    func pagerMoved(to position: CGFloat) {
      if !isScrubbing, position != position.rounded(), preview?.isWaitingForPage == true { preview?.reset() }
      strip?.follow(position)
    }

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
      didSet {
        endScrub()
        reload()
        link?.preview?.reset()
        link?.readyID = nil
      }
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
    private var committedIndex = -1
    private var slices: [Int: Slice] = [:]
    private var pool: [Slice] = []
    private var landing: [ThumbnailTicket] = []
    fileprivate var isScrubbing: Bool { trackingScrub || isStressing }
    private var trackingScrub = false
    private var adjustingInset = false
    private var isStressing = false

    #if DEBUG
      /// Scrubs across the strip at about 25 photos a second, through the same path as a
      /// finger, and logs frame times (`-UIScreen cloudFilmstripStress`).
      func runStress(seconds: TimeInterval) {
        isStressing = true
        trackingScrub = true
        link?.preview?.startStress()
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
      var identity: ThumbnailIdentity?
      var ticket: ThumbnailTicket?
      var needsUpgrade = false
      var image: CGImage?

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
        self.image = image
        contents = image
        cropContents()
      }

      /// Fills the slice with the middle of the image, as aspect-fill would.
      func cropContents() {
        guard let image, bounds.height > 0 else { return }
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
      decelerationRate = .normal
      clipsToBounds = false
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
      isAccessibilityElement = true
      accessibilityLabel = String(localized: "Filmstrip")
      accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    func tearDown() {
      endScrub()
      reload()
      link?.preview?.reset()
    }

    /// Follows the viewer's page, unless the user is moving the strip.
    func show(_ index: Int, count: Int, thumbnailRevision: Int) {
      committedIndex = index
      if thumbnailRevision != self.thumbnailRevision {
        cancelLanding()
        link?.preview?.invalidateRequest()
      }
      if count != self.count {
        cancelLanding()
        self.count = count
        contentSize = CGSize(width: CGFloat(max(count - 1, 0)) * pitch + Self.sliceWidth, height: Self.height)
      }
      if let source {
        for (position, slice) in slices {
          if position >= count || slice.identity != source.thumbnailIdentity(at: position) {
            slices[position] = nil
            recycle(slice)
          } else if thumbnailRevision != self.thumbnailRevision {
            requestImage(for: slice, source: source.thumbnailSource, fast: isScrubbing)
          }
        }
      }
      self.thumbnailRevision = thumbnailRevision
      if isScrubbing {
        layoutSlices()
        showPreview(at: centeredIndex, dwell: true)
        return
      }
      if index != shownIndex {
        shownIndex = index
        let target = offset(for: index)
        // After a swipe the strip has followed the finger and is nearly there already.
        let near = abs(contentOffset.x - target) < pitch * 0.75
        let animated = !near && window != nil && !UIAccessibility.isReduceMotionEnabled
        setContentOffset(CGPoint(x: target, y: 0), animated: animated)
      }
      layoutSlices()
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
        let position = (contentOffset.x + contentInset.left) / pitch
        adjustingInset = true
        contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if isScrubbing {
          contentOffset.x = position * pitch - inset
        } else if shownIndex >= 0 {
          contentOffset.x = offset(for: shownIndex)
        }
        adjustingInset = false
      }
      if bounds.size != laidOutSize || slices.isEmpty {
        laidOutSize = bounds.size
        layoutSlices()
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !adjustingInset else { return }
      layoutSlices()
      guard isScrubbing, count > 0 else { return }
      let index = centeredIndex
      guard index != shownIndex else { return }
      shownIndex = index
      if isDragging, abs(panGestureRecognizer.velocity(in: self).x) < 600 {
        feedback.selectionChanged()
        feedback.prepare()
      }
      showPreview(at: index, dwell: true)
      link?.scrubbed(to: index)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      trackingScrub = true
      cancelLanding()
      link?.preview?.resumeScrub()
      feedback.prepare()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { finishScrub() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrub() }

    private func finishScrub() {
      guard trackingScrub else { return }
      trackingScrub = false
      guard count > 0 else { return endScrub() }
      commit(centeredIndex, animated: false)
    }

    private func showPreview(at index: Int, dwell: Bool) {
      guard let source, index >= 0, index < count else { return }
      let pixels = source.aspectRatio(at: index).map { CGSize(width: $0, height: 1) } ?? .zero
      link?.preview?.show(
        identity: slices[index]?.identity ?? source.thumbnailIdentity(at: index), pixels: pixels, slice: slices[index]?.image,
        source: source.thumbnailSource, dwell: dwell, onDwell: { [weak self] in self?.upgradeSlices() })
    }

    private func commit(_ index: Int, animated: Bool) {
      trackingScrub = false
      shownIndex = index
      setContentOffset(CGPoint(x: offset(for: index), y: 0), animated: animated)
      layoutSlices()
      upgradeSlices()
      showPreview(at: index, dwell: false)
      cancelLanding(keeping: source?.thumbnailIdentity(at: index).id)
      defer { link?.scrubbed(to: nil) }
      guard let link, let source else {
        onScrub(index)
        return
      }
      let id = source.itemID(at: index)
      link.preview?.commit(id: id, alreadyReady: committedIndex == index && link.readyID == id)
      if link.readyID != id { link.readyID = nil }
      onScrub(index)
    }

    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      // Comes to rest with a slice in the middle.
      let position = (targetContentOffset.pointee.x + contentInset.left) / pitch
      let index = min(max(Int(position.rounded()), 0), max(count - 1, 0))
      targetContentOffset.pointee.x = offset(for: index)
      if index != centeredIndex { prepareLanding(at: index) }
    }

    /// Loads what the fling will stop on while it's still moving, nearest the middle first.
    private func prepareLanding(at index: Int) {
      cancelLanding()
      guard let source, count > 0, bounds.width > 0 else { return }
      let reach = Int((bounds.width / 2 / pitch).rounded(.up))
      let thumbnails = source.thumbnailSource
      if let pixels = source.aspectRatio(at: index) {
        link?.preview?.prepare(
          identity: source.thumbnailIdentity(at: index), pixels: CGSize(width: pixels, height: 1), source: thumbnails)
      }
      for distance in 0...reach {
        for position in Set([index - distance, index + distance]) where position >= 0 && position < count {
          let identity = source.thumbnailIdentity(at: position)
          guard !identity.isLocked else { continue }
          landing.append(
            ThumbnailPipeline.shared.load(
              ThumbnailKey(identity: identity, bucket: .small), from: thumbnails, quality: .thumbnail
            ) { [weak self] image, isFinal in
              guard let self else { return }
              if let slice = self.slices[position], slice.identity == identity,
                ViewerImage.accepts(image, over: slice.image, isFinal: isFinal)
              {
                slice.setImage(image)
              }
              self.link?.preview?.receive(image, identity: identity, isFinal: isFinal, isWhole: false)
            })
        }
      }
    }

    private func cancelLanding(keeping id: String? = nil) {
      for ticket in landing { ticket.cancel() }
      landing = []
      link?.preview?.cancelLanding(keeping: id)
    }

    fileprivate func interruptFling() {
      guard trackingScrub, !isTracking else { return }
      endScrub()
      setContentOffset(contentOffset, animated: false)
      link?.preview?.reset()
    }

    /// The strip went away or lost its items mid-scrub: the viewer's actions come back.
    private func endScrub() {
      cancelLanding()
      trackingScrub = false
      link?.scrubbed(to: nil)
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
      commit(index, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      let x = recognizer.location(in: self).x
      guard let (index, _) = slices.min(by: { abs($0.value.frame.midX - x) < abs($1.value.frame.midX - x) }) else { return }
      commit(index, animated: !UIAccessibility.isReduceMotionEnabled)
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
      let identity = source.thumbnailIdentity(at: index)
      slice.identity = identity
      let key = ThumbnailKey(identity: identity, bucket: .huge)
      let cache = ThumbnailPipeline.shared
      let cached = cache.placeholder(for: key) ?? cache.viewerPreview(for: identity)
      slice.setImage(cached)
      if ViewerImage.longSide(cached) < 96 {
        requestImage(for: slice, source: source.thumbnailSource, fast: isScrubbing)
      }
      return slice
    }

    private func upgradeSlices() {
      guard let source else { return }
      for slice in slices.values where slice.needsUpgrade {
        requestImage(for: slice, source: source.thumbnailSource, fast: false)
      }
    }

    private func requestImage(for slice: Slice, source: any ThumbnailSource, fast: Bool) {
      guard let identity = slice.identity else { return }
      slice.ticket?.cancel()
      slice.needsUpgrade = fast
      // During a scrub, a newly exposed Google item only checks the cache.
      let key = ThumbnailKey(identity: identity, bucket: fast ? .tiny : .small)
      slice.ticket = ThumbnailPipeline.shared.load(key, from: source, quality: fast ? .fast : .thumbnail) {
        [weak self, weak slice] image, isFinal in
        guard let slice, slice.identity == identity, ViewerImage.accepts(image, over: slice.image, isFinal: isFinal) else { return }
        slice.setImage(image)
        self?.link?.preview?.receive(image, identity: identity, isFinal: isFinal, isWhole: false)
      }
    }

    private func recycle(_ slice: Slice) {
      slice.ticket?.cancel()
      slice.ticket = nil
      slice.identity = nil
      slice.setImage(nil)
      slice.needsUpgrade = false
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
    private var target: ThumbnailIdentity?
    private var imageIdentity: ThumbnailIdentity?
    private var image: CGImage?
    private var isWhole = false
    private var pixels: CGSize = .zero
    private var imagePixels: CGSize = .zero
    private var token: ThumbnailTicket?
    private var landingToken: ThumbnailTicket?
    private var landingID: String?
    private var detailTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var committedID: String?
    var isWaitingForPage: Bool { committedID != nil }
    #if DEBUG
      private var stressHits = 0
      private var stressMisses = 0
      private var stressRunning = false
      private var stressCommitTime: CFTimeInterval?

      func startStress() {
        stressHits = 0
        stressMisses = 0
        stressRunning = true
      }
    #endif

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isHidden = true
      backgroundColor = .systemBackground
      imageLayer.contentsGravity = .resizeAspect
      imageLayer.masksToBounds = true
      imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsGravity": NSNull()]
      layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
      super.layoutSubviews()
      layoutImage()
    }

    private func layoutImage() {
      guard let image else { return }
      let cropped = !isWhole && !ViewerImage.matchesAspect(image, imagePixels)
      let size = AspectFit.size(for: cropped ? imagePixels : ViewerImage.size(image), in: bounds.size)
      imageLayer.frame = CGRect(
        x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
        width: size.width, height: size.height)
      // Filling a very long shape with a square crop would blow it up.
      let shape = imagePixels.width > 0 && imagePixels.height > 0 ? imagePixels.width / imagePixels.height : 1
      imageLayer.contentsGravity = cropped && max(shape, 1 / shape) < 2 ? .resizeAspectFill : .resizeAspect
    }

    func invalidateRequest() { reset() }

    func cancelLanding(keeping id: String? = nil) {
      guard id == nil || id != landingID else { return }
      landingToken?.cancel()
      landingToken = nil
      landingID = nil
    }

    /// The photo a fling will stop on, loaded on the way there.
    func prepare(identity: ThumbnailIdentity, pixels: CGSize, source: any ThumbnailSource) {
      cancelLanding()
      guard !identity.isLocked else { return }
      let scale = traitCollection.displayScale
      let target = Self.dwellPixels(pixels, in: CGSize(width: bounds.width * scale, height: bounds.height * scale))
      let isFile = FolderItemInfo.path(fromID: identity.id) != nil
      guard target != .zero, !ViewerImage.hasFittedPreview(for: identity, target: target, isFile: isFile) else { return }
      landingID = identity.id
      landingToken = ViewerImage.request(source, identity: identity, pixels: target, isFile: isFile) { [weak self] image, isFinal in
        self?.receive(image, identity: identity, isFinal: isFinal, isWhole: true)
      }
    }

    func resumeScrub() {
      hideTask?.cancel()
      committedID = nil
    }

    func show(
      identity: ThumbnailIdentity, pixels: CGSize, slice: CGImage?, source: any ThumbnailSource,
      dwell: Bool, onDwell: @escaping () -> Void
    ) {
      guard identity != target else { return }
      resumeScrub()
      target = identity
      self.pixels = pixels
      detailTask?.cancel()
      token?.cancel()
      token = nil

      if imageIdentity?.isLocked == true || identity.isLocked {
        reset()
        return
      }
      let pipeline = ThumbnailPipeline.shared
      let whole = pipeline.viewerPreview(for: identity)
      let cached = ViewerImage.preview(
        whole: whole, thumbnail: whole == nil ? pipeline.placeholder(for: ThumbnailKey(identity: identity, bucket: .huge)) : nil,
        slice: slice, pixels: pixels)
      #if DEBUG
        if stressRunning {
          if cached == nil { stressMisses += 1 } else { stressHits += 1 }
        }
      #endif
      if let cached {
        receive(cached, identity: identity, isFinal: true, isWhole: whole != nil)
      }
      guard dwell else { return }
      // A pause can sharpen; crossing an item does not download its display image.
      detailTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard let self, !Task.isCancelled, self.target == identity else { return }
        onDwell()
        let scale = self.traitCollection.displayScale
        let container = CGSize(width: self.bounds.width * scale, height: self.bounds.height * scale)
        let target = Self.dwellPixels(pixels, in: container)
        let isFile = FolderItemInfo.path(fromID: identity.id) != nil
        guard target != .zero, !ViewerImage.hasFittedPreview(for: identity, target: target, isFile: isFile) else { return }
        self.token = ViewerImage.request(source, identity: identity, pixels: target, isFile: isFile) { [weak self] image, isFinal in
          self?.receive(image, identity: identity, isFinal: isFinal, isWhole: true)
        }
      }
    }

    static func dwellPixels(_ pixels: CGSize, in container: CGSize) -> CGSize {
      guard pixels.width > 0, pixels.height > 0 else {
        let side = max(container.width, container.height)
        return CGSize(width: side, height: side)
      }
      return AspectFit.size(for: pixels, in: container)
    }

    func receive(_ candidate: CGImage, identity: ThumbnailIdentity, isFinal: Bool, isWhole: Bool) {
      guard identity == target, !identity.isLocked else { return }
      if imageIdentity == identity {
        let betterAspect =
          (isWhole || ViewerImage.matchesAspect(candidate, pixels))
          != (self.isWhole || image.map { ViewerImage.matchesAspect($0, pixels) } == true)
        if betterAspect {
          guard isWhole || ViewerImage.matchesAspect(candidate, pixels) else { return }
        } else {
          guard ViewerImage.accepts(candidate, over: image, isFinal: isFinal) else { return }
        }
      }
      imageIdentity = identity
      image = candidate
      imagePixels = pixels
      self.isWhole = isWhole
      layoutImage()
      imageLayer.contents = candidate
      isHidden = false
    }

    func handoffImage(for id: String) -> CGImage? {
      committedID == id && imageIdentity?.id == id && imageIdentity?.isLocked == false ? image : nil
    }

    func commit(id: String, alreadyReady: Bool) {
      detailTask?.cancel()
      committedID = id
      #if DEBUG
        if stressRunning {
          stressCommitTime = CACurrentMediaTime()
          stressRunning = false
          NSLog("STRESS filmstrip previews hits=%d misses=%d", stressHits, stressMisses)
        }
      #endif
      if alreadyReady {
        pageImageReady(id)
        return
      }
      hideTask?.cancel()
      hideTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        #if DEBUG
          if self.stressCommitTime != nil { NSLog("STRESS filmstrip handoff timed out") }
        #endif
        self.reset()
      }
    }

    func pageImageReady(_ id: String) {
      guard committedID == id else { return }
      #if DEBUG
        if let start = stressCommitTime {
          NSLog("STRESS filmstrip commitToImage=%.2fms", (CACurrentMediaTime() - start) * 1000)
        }
      #endif
      reset(cancelDetail: false)
    }

    func reset(cancelDetail: Bool = true) {
      hideTask?.cancel()
      detailTask?.cancel()
      if cancelDetail {
        token?.cancel()
        token = nil
        cancelLanding()
      }
      isHidden = true
      target = nil
      committedID = nil
      imageIdentity = nil
      image = nil
      imageLayer.contents = nil
      #if DEBUG
        stressCommitTime = nil
      #endif
    }
  }
#endif
