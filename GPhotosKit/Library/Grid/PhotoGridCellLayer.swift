import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// One grid cell. The thumbnail is the layer's own `contents`, cropped to a square with
/// `contentsRect` instead of a mask, so the GPU draws one textured quad with no offscreen
/// pass. Badges are small sublayers created only when a cell needs them.
final class PhotoGridCellLayer: CALayer {
  // Never mutated after initialization.
  nonisolated(unsafe) static let noActions: [String: any CAAction] = [
    "contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull(),
    "hidden": NSNull(), "sublayers": NSNull(), "opacity": NSNull(), "string": NSNull(), "frame": NSNull(),
  ]

  var itemID: String?
  var ticket: ThumbnailTicket?
  @MainActor var isSelected = false {
    didSet {
      guard isSelected != oldValue else { return }
      updateSelection()
    }
  }

  /// The empty circle a click selects with (Mac), shown on hover and while selecting.
  @MainActor var showsSelectionCircle = false {
    didSet {
      guard showsSelectionCircle != oldValue else { return }
      updateSelection()
    }
  }

  private var badges = PhotoGridBadges()
  private var badgeScale: CGFloat = 0
  /// On iPhone the check sits in the corner where a video's length is.
  private var checkCoversDuration = false
  private var shade: CAGradientLayer?
  private var durationLayer: CATextLayer?
  private var favoriteLayer: CALayer?
  private var backupLayer: CALayer?
  private var selectionLayer: CALayer?
  private var circleLayer: CALayer?

  override init() {
    super.init()
    configure()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    contentsGravity = .resize
    backgroundColor = Self.placeholderColor
    isOpaque = true
    anchorPoint = .zero
  }

  override func action(forKey event: String) -> (any CAAction)? { NSNull() }

  @MainActor func setImage(_ image: CGImage) {
    contents = image
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard width > 0, height > 0 else { return }
    contentsRect =
      width > height
      ? CGRect(x: (1 - height / width) / 2, y: 0, width: height / width, height: 1)
      : CGRect(x: 0, y: (1 - width / height) / 2, width: 1, height: width / height)
  }

  @MainActor func prepareForReuse() {
    ticket?.cancel()
    ticket = nil
    itemID = nil
    contents = nil
    isSelected = false
    showsSelectionCircle = false
  }

  override func layoutSublayers() {
    super.layoutSublayers()
    layoutBadges()
  }

  @MainActor func apply(badges newBadges: PhotoGridBadges, scale: CGFloat) {
    guard newBadges != badges || scale != badgeScale else { return }
    badges = newBadges
    badgeScale = scale
    let needsShade = newBadges.videoDuration != nil || newBadges.isFavorite
    if needsShade, shade == nil {
      let gradient = CAGradientLayer()
      gradient.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.45)]
      gradient.locations = [0.55, 1]
      gradient.actions = Self.noActions
      addSublayer(gradient)
      shade = gradient
    }
    shade?.isHidden = !needsShade

    if let duration = newBadges.videoDuration {
      let text = durationLayer ?? makeTextLayer()
      durationLayer = text
      text.contentsScale = scale
      text.string = Self.format(duration: duration)
      text.isHidden = false
    } else {
      durationLayer?.isHidden = true
    }

    if newBadges.isFavorite {
      let layer = favoriteLayer ?? makeIconLayer()
      favoriteLayer = layer
      layer.contents = SymbolImageCache.image("heart.fill", scale: scale)
      layer.isHidden = false
    } else {
      favoriteLayer?.isHidden = true
    }

    if let backup = newBadges.backup {
      let layer = backupLayer ?? makeIconLayer()
      backupLayer = layer
      let symbol =
        switch backup {
        case .pending: "arrow.up.circle.fill"
        case .cloudOnly: "cloud.fill"
        case .backedUp: "checkmark.icloud.fill"
        default: "exclamationmark.circle.fill"
        }
      // Alone in its corner, with no shade behind it: its own soft shadow keeps it readable
      // on a bright photo.
      layer.contents = SymbolImageCache.image(symbol, scale: scale, shadow: true)
      layer.isHidden = false
    } else {
      backupLayer?.isHidden = true
    }
    setNeedsLayout()
  }

  private struct BadgeLayout {
    var shows: Bool
    var duration: CGRect
    var favorite: CGRect
    var backup: CGRect
    var check: CGRect
  }

  private static func badgeLayout(side: CGFloat) -> BadgeLayout {
    let icon: CGFloat = side >= 100 ? 16 : 13
    let inset: CGFloat = 5
    return BadgeLayout(
      // Tiny cells (year-like zoom levels) are too small for badges to read.
      shows: side >= 56,
      duration: CGRect(x: inset, y: side - inset - 15, width: side - inset * 2, height: 15),
      favorite: CGRect(x: inset, y: side - inset - icon, width: icon, height: icon),
      // Room for the shadow drawn around the symbol, which stays the size it was.
      backup: CGRect(x: side - inset - icon, y: inset, width: icon, height: icon)
        .insetBy(dx: -SymbolImageCache.shadowPadding * icon / 24, dy: -SymbolImageCache.shadowPadding * icon / 24),
      check: checkFrame(side: side, inset: inset))
  }

  /// Bottom right on iPhone, as in Photos; top left on the Mac, as on Google Photos for
  /// the web, where the pointer finds it before clicking.
  private static func checkFrame(side: CGFloat, inset: CGFloat) -> CGRect {
    #if os(macOS)
      let size: CGFloat = side >= 100 ? 22 : 18
      return CGRect(x: inset + 1, y: inset + 1, width: size, height: size)
    #else
      return CGRect(x: side - inset - 22, y: side - inset - 22, width: 22, height: 22)
    #endif
  }

  private func layoutBadges() {
    let layout = Self.badgeLayout(side: bounds.width)
    let opacity: Float = layout.shows ? 1 : 0
    shade?.frame = bounds
    shade?.opacity = opacity
    durationLayer?.frame = layout.duration
    durationLayer?.opacity = checkCoversDuration ? 0 : opacity
    favoriteLayer?.frame = layout.favorite
    favoriteLayer?.opacity = opacity
    backupLayer?.frame = layout.backup
    backupLayer?.opacity = opacity
    selectionLayer?.frame = bounds
    selectionLayer?.sublayers?.first?.frame = layout.check
    circleLayer?.frame = bounds
    circleLayer?.sublayers?.first?.frame = layout.check
  }

  /// Where a click selects the item rather than opening it, in the cell's coordinates.
  static func checkRect(side: CGFloat) -> CGRect { badgeLayout(side: side).check }

  /// The badges follow a size change the cell is animating with `animation`, instead of
  /// jumping to where they sit at the new size while the cell is still on its way.
  func animateBadges(fromSide oldSide: CGFloat, animation: (String) -> CABasicAnimation) {
    layoutBadges()
    let old = Self.badgeLayout(side: oldSide)
    let new = Self.badgeLayout(side: bounds.width)
    func move(_ layer: CALayer?, from: CGRect, to: CGRect) {
      guard let layer, !layer.isHidden, from != to else { return }
      let position = animation("position")
      position.fromValue = CGPoint(x: from.midX, y: from.midY)
      layer.add(position, forKey: "position")
      let size = animation("bounds.size")
      size.fromValue = from.size
      layer.add(size, forKey: "bounds.size")
    }
    let oldBounds = CGRect(x: 0, y: 0, width: oldSide, height: oldSide)
    move(shade, from: oldBounds, to: bounds)
    move(durationLayer, from: old.duration, to: new.duration)
    move(favoriteLayer, from: old.favorite, to: new.favorite)
    move(backupLayer, from: old.backup, to: new.backup)
    move(selectionLayer, from: oldBounds, to: bounds)
    move(selectionLayer?.sublayers?.first, from: old.check, to: new.check)
    move(circleLayer, from: oldBounds, to: bounds)
    move(circleLayer?.sublayers?.first, from: old.check, to: new.check)
    if old.shows != new.shows {
      for layer in [shade, durationLayer, favoriteLayer, backupLayer] as [CALayer?] {
        guard let layer, !layer.isHidden, !(checkCoversDuration && layer === durationLayer) else { continue }
        let fade = animation("opacity")
        fade.fromValue = old.shows ? 1 : 0
        layer.add(fade, forKey: "opacity")
      }
    }
  }

  /// The badges fade in over a photo that has just landed back in its cell (closing the
  /// viewer), as in Photos, rather than appearing with it.
  func fadeInBadges(duration: CFTimeInterval) {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    for layer in [shade, durationLayer, favoriteLayer, backupLayer] as [CALayer?] {
      guard let layer, !layer.isHidden else { continue }
      layer.add(fade, forKey: "fadeIn")
    }
  }

  /// Drops the badges' animations along with the cell's own.
  func removeBadgeAnimations() {
    for layer in [
      shade, durationLayer, favoriteLayer, backupLayer, selectionLayer, selectionLayer?.sublayers?.first, circleLayer,
      circleLayer?.sublayers?.first,
    ] as [CALayer?] {
      layer?.removeAllAnimations()
    }
  }

  private func makeTextLayer() -> CATextLayer {
    let text = CATextLayer()
    text.actions = Self.noActions
    text.alignmentMode = .right
    text.fontSize = 12
    text.font = CTFontCreateUIFontForLanguage(.system, 12, nil).map { $0 as CFTypeRef }
    text.foregroundColor = CGColor(gray: 1, alpha: 1)
    addSublayer(text)
    return text
  }

  private func makeIconLayer() -> CALayer {
    let layer = CALayer()
    layer.actions = Self.noActions
    layer.contentsGravity = .resizeAspect
    addSublayer(layer)
    return layer
  }

  @MainActor private func updateSelection() {
    if isSelected, selectionLayer == nil {
      let overlay = CALayer()
      overlay.actions = Self.noActions
      overlay.backgroundColor = CGColor(gray: 1, alpha: 0.25)
      let check = CALayer()
      check.actions = Self.noActions
      check.contentsGravity = .resizeAspect
      check.contents = SymbolImageCache.image("checkmark.circle.fill", scale: max(badgeScale, 2), accent: true)
      overlay.addSublayer(check)
      addSublayer(overlay)
      selectionLayer = overlay
      setNeedsLayout()
    }
    selectionLayer?.isHidden = !isSelected
    #if os(iOS)
      if checkCoversDuration != isSelected {
        checkCoversDuration = isSelected
        setNeedsLayout()
      }
    #endif
    let showsCircle = showsSelectionCircle && !isSelected
    if showsCircle, circleLayer == nil {
      // A soft shade along the top keeps the white circle readable on bright photos.
      let shade = CAGradientLayer()
      shade.actions = Self.noActions
      shade.colors = [CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0)]
      shade.locations = [0, 0.4]
      let circle = CALayer()
      circle.actions = Self.noActions
      circle.contentsGravity = .resizeAspect
      circle.contents = SymbolImageCache.image("circle", scale: max(badgeScale, 2))
      shade.addSublayer(circle)
      addSublayer(shade)
      circleLayer = shade
      setNeedsLayout()
    }
    circleLayer?.isHidden = !showsCircle
  }

  private static let placeholderColor: CGColor = {
    #if canImport(UIKit)
      UIColor.secondarySystemFill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
    #else
      NSColor.quaternaryLabelColor.cgColor
    #endif
  }()

  @MainActor private static let longDurationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.zeroFormattingBehavior = .pad
    formatter.unitsStyle = .positional
    return formatter
  }()

  @MainActor static func format(duration: TimeInterval) -> String {
    let rounded = duration.rounded()
    guard rounded < 3600 else { return longDurationFormatter.string(from: rounded) ?? "" }
    // As in Photos: 0:09, 1:59.
    let seconds = Int(rounded)
    return "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
  }
}

/// SF Symbols rendered once per name and scale as white (or accent) bitmaps for layers.
@MainActor
enum SymbolImageCache {
  private static var images: [String: CGImage] = [:]

  /// Points of clear space around a symbol drawn with a shadow.
  nonisolated static let shadowPadding: CGFloat = 4

  static func image(_ name: String, scale: CGFloat, accent: Bool = false, shadow: Bool = false) -> CGImage? {
    let key = "\(name)|\(scale)|\(accent)|\(shadow)"
    if let cached = images[key] { return cached }
    var rendered = render(name, scale: scale, accent: accent)
    if shadow, let plain = rendered { rendered = shadowed(plain, scale: scale) }
    images[key] = rendered
    return rendered
  }

  /// The shadow is part of the bitmap, so a cell still draws one quad for its badge; a
  /// layer shadow would cost every cell an offscreen pass.
  private static func shadowed(_ image: CGImage, scale: CGFloat) -> CGImage {
    let padding = Int((shadowPadding * scale).rounded())
    guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(
        data: nil, width: image.width + padding * 2, height: image.height + padding * 2, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    context.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: 2.5 * scale, color: CGColor(gray: 0, alpha: 0.5))
    context.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
    return context.makeImage() ?? image
  }

  private static func render(_ name: String, scale: CGFloat, accent: Bool) -> CGImage? {
    let pointSize: CGFloat = 22
    #if canImport(UIKit)
      let colors: [UIColor] = accent ? [.white, .tintColor] : [.white]
      let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(UIImage.SymbolConfiguration(paletteColors: colors))
      guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
      let format = UIGraphicsImageRendererFormat.preferred()
      format.scale = scale
      return UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in symbol.draw(at: .zero) }.cgImage
    #else
      let colors: [NSColor] = accent ? [.white, .controlAccentColor] : [.white]
      let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
      guard
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration)
      else { return nil }
      var rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale))
      return symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    #endif
  }
}
