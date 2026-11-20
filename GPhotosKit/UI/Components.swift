import SwiftUI

// MARK: - Surfaces

/// The corner radii shared by every surface.
public enum Radius {
  public static let hero: CGFloat = 28
  public static let card: CGFloat = 22
  public static let inset: CGFloat = 16
  public static let chip: CGFloat = 10
}

extension View {
  /// The app's one card surface: Liquid Glass, optionally washed with a status tint.
  public func glassCard(cornerRadius: CGFloat = Radius.card, tint: Color? = nil, interactive: Bool = false) -> some View {
    modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
  }
}

private struct GlassCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?
  let interactive: Bool
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint.opacity(colorScheme == .dark ? 0.10 : 0.14)) }
    if interactive { glass = glass.interactive() }
    return content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
  }
}

extension View {
  /// A neutral glass surface for grouped content inside sheets. Color lives in the row icons.
  public func tintedSurface(in shape: some InsettableShape = .rect(cornerRadius: Radius.inset + 2, style: .continuous)) -> some View {
    glassEffect(.regular, in: shape).contentShape(shape)
  }

  /// Source-compatible form; the tint is ignored.
  public func tintedSurface(
    _ tint: Color, in shape: some InsettableShape = .rect(cornerRadius: Radius.inset + 2, style: .continuous)
  ) -> some View {
    tintedSurface(in: shape)
  }
}

/// A colored rounded-square icon tile, as used across Apple's Settings.
public struct IconTile: View {
  private let symbol: String
  private let colors: [Color]
  private let size: CGFloat

  public init(symbol: String, colors: [Color], size: CGFloat) {
    self.symbol = symbol
    self.colors = colors
    self.size = size
  }

  public var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
        in: .rect(cornerRadius: size * 0.27, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

// MARK: - Status

/// The circular emblem that leads every status surface.
public struct StatusEmblem: View {
  private let status: BackupStatus
  @ScaledMetric private var size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(_ status: BackupStatus, size: CGFloat = 44) {
    self.status = status
    _size = ScaledMetric(wrappedValue: size, relativeTo: .headline)
  }

  public var body: some View {
    let size = min(size, 56)
    return ZStack {
      // A flat fill under a fixed highlight, so the color itself animates between states.
      Circle()
        .fill(status.tint)
        .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)))
      // Keyed on the symbol so each state starts fresh: no pulse left fading on the new glyph,
      // and the new one draws in rather than cross-fading.
      Image(systemName: status.symbol)
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.white)
        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: status.rotates && !reduceMotion)
        .symbolEffect(.pulse, isActive: status.isActive && !status.rotates && !reduceMotion)
        .id(status.symbol)
        .transition(.symbolEffect(.drawOn))
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Live numbers for the transfer in progress, read once per render from the pool.
public struct TransferProgressSummary: Equatable {
  public var fraction: Double
  public var filename: String?
  /// The record behind `filename`, so the card can show its thumbnail.
  public var record: TransferRecord?
  public var remaining: String
  public var dataText: String = ""
  public var speed: String

  public init(fraction: Double, filename: String?, record: TransferRecord? = nil, remaining: String, speed: String) {
    self.fraction = fraction
    self.filename = filename
    self.record = record
    self.remaining = remaining
    self.speed = speed
  }

  @MainActor
  public init(_ pool: UploadWorkerPool) {
    fraction = pool.currentProgress
    filename = pool.currentFilename.flatMap { $0.isEmpty ? nil : $0 }
    remaining = pool.overallFormattedETA
    dataText = "\(ByteFormat.string(pool.completedItemsBytes)) of \(ByteFormat.string(pool.currentTotalBytes)) backed up"
    speed = pool.overallFormattedSpeed
  }
}

/// The hero card: what is happening, how far along it is, and the one action that matters.
public struct StatusCard<Actions: View>: View {
  private let status: BackupStatus
  private let progress: TransferProgressSummary?
  private let actions: Actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  public init(status: BackupStatus, progress: TransferProgressSummary?, @ViewBuilder actions: () -> Actions) {
    self.status = status
    self.progress = progress
    self.actions = actions()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // One layout per size class, so the card never flips between arrangements as
      // its text changes length.
      let layout =
        stacksActions
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        : AnyLayout(HStackLayout(spacing: 14))
      layout {
        header
          .frame(maxWidth: .infinity, alignment: .leading)
        actions
          .id(status.kind)
          .transition(.blurReplace)
          .fixedSize()
      }
      if let progress {
        ProgressBlock(progress: progress, tint: status.tint, showsRate: status != .waitingForNetwork && status != .rateLimited)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(cornerRadius: Radius.hero, tint: status.tint)
    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: status.kind)
    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: progress == nil)
  }

  private var stacksActions: Bool {
    #if os(iOS)
      dynamicTypeSize.isAccessibilitySize || (horizontalSizeClass == .compact && status.hasSecondaryAction)
    #else
      dynamicTypeSize.isAccessibilitySize
    #endif
  }

  private var header: some View {
    HStack(spacing: 14) {
      StatusEmblem(status)
      // Title and subtitle change together as one block; fading them separately overlaps
      // two lines of different widths.
      VStack(alignment: .leading, spacing: 2) {
        Text(status.title)
          .font(.headline)
          .contentTransition(.numericText())
          .accessibilityAddTraits(.isHeader)
        Text(status.subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .id(status.kind)
      .transition(.blurReplace)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ProgressBlock: View {
  let progress: TransferProgressSummary
  let tint: Color
  /// Time left and speed are stale while uploads are held for Wi‑Fi.
  let showsRate: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var fraction: Double {
    progress.fraction.isNaN ? 0 : min(max(progress.fraction, 0), 1)
  }

  var body: some View {
    HStack(spacing: 12) {
      if let filename = progress.filename {
        UploadThumbnail(record: progress.record, filename: filename, size: 40)
          // A new file fades in rather than morphing the previous file's image.
          .id(progress.record?.id ?? filename)
          .transition(.opacity)
      }
      bar
    }
    .animation(reduceMotion ? nil : .smooth, value: progress.record?.id ?? progress.filename)
  }

  private var bar: some View {
    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: fraction)
        .tint(tint)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: fraction)
        .accessibilityLabel("Upload progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
      if !progress.dataText.isEmpty {
        HStack {
          Text(progress.dataText)
          Spacer(minLength: 8)
          Text(fraction, format: .percent.precision(.fractionLength(0)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
      HStack(spacing: 8) {
        if let filename = progress.filename {
          Text(filename)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 8)
        if showsRate {
          Text([progress.remaining, progress.speed].filter { !$0.isEmpty }.joined(separator: " · "))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }
  }
}

/// Scales and dims a custom tappable on press, with a critically damped spring.
public struct PressableButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
  }
}

// MARK: - Stat tiles

/// One count in the dashboard's summary row. Tapping it opens the matching activity.
public struct StatTile: View {
  // Caption 2 is 10pt on the Mac, too small to read on glass.
  #if os(macOS)
    private static let detailFont: Font = .caption
  #else
    private static let detailFont: Font = .caption2
  #endif

  private let title: LocalizedStringKey
  private let value: Int
  private let detail: String
  private let symbol: String
  private let tint: Color
  private let isActive: Bool
  private let action: () -> Void
  @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 38
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    _ title: LocalizedStringKey, value: Int, detail: String, symbol: String, tint: Color, isActive: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.value = value
    self.detail = detail
    self.symbol = symbol
    self.tint = tint
    self.isActive = isActive
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      let isAccessibility = dynamicTypeSize.isAccessibilitySize
      let layout =
        isAccessibility
        ? AnyLayout(HStackLayout(spacing: 14))
        : AnyLayout(VStackLayout(spacing: 8))
      let side = isAccessibility ? min(iconSize, 56) : iconSize
      layout {
        Image(systemName: symbol)
          .font(.headline)
          .foregroundStyle(tint)
          .symbolEffect(.pulse, isActive: isActive && !reduceMotion)
          .frame(width: side, height: side)
          .background(tint.opacity(0.14), in: .circle)
        VStack(alignment: isAccessibility ? .leading : .center, spacing: 1) {
          Text(value, format: .number)
            .font(.title3.weight(.bold))
            .monospacedDigit()
            .lineLimit(isAccessibility ? nil : 1)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
            .animation(reduceMotion ? nil : .smooth, value: value)
          Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(isAccessibility ? nil : 1)
          Text(detail)
            .font(Self.detailFont)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(isAccessibility ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: isAccessibility ? .leading : .center)
      .padding(.vertical, 14)
      .padding(.horizontal, isAccessibility ? 14 : 6)
      .contentShape(.rect(cornerRadius: Radius.card))
    }
    .buttonStyle(PressableButtonStyle())
    .glassCard(cornerRadius: Radius.card, interactive: true)
    .accessibilityLabel(title)
    .accessibilityValue(Text("\(value), \(detail)"))
    .accessibilityHint("Shows these items in Activity")
  }
}

// MARK: - Rows

/// A settings row label with the colored rounded-square icon used across Apple's Settings.
public struct SettingLabel: View {
  private let title: LocalizedStringKey
  private let detail: LocalizedStringKey?
  private let symbol: String
  private let colors: [Color]
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = SettingLabel.baseIconSize

  #if os(macOS)
    static let baseIconSize: CGFloat = 28
  #else
    static let baseIconSize: CGFloat = 34
  #endif

  /// `colors` paint the icon tile as a top-leading to bottom-trailing gradient.
  public init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, symbol: String, colors: [Color]) {
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.colors = colors
  }

  /// The gap between the icon tile and the text.
  static let iconSpacing: CGFloat = 14

  /// The leading offset of the text column for an icon tile of the given size.
  public static func textInset(iconSize: CGFloat) -> CGFloat { iconSize + iconSpacing }

  public var body: some View {
    // Centered on the whole title-and-detail block, as in Settings, rather than on the
    // title's first line, which drops a tall tile into the description.
    HStack(alignment: .center, spacing: Self.iconSpacing) {
      IconTile(symbol: symbol, colors: colors, size: iconSize)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.semibold))
        if let detail { detailText(detail) }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func detailText(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A Google account's profile photo, or its initial until the photo has loaded.
public struct AccountAvatar: View {
  private let email: String?
  @ScaledMetric private var size: CGFloat

  public init(email: String?, size: CGFloat = 32) {
    self.email = email.map(AccountPhotoStore.emailKey)
    _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
  }

  public var body: some View {
    Group {
      if let email, let photo = AccountPhotoStore.shared.photo(for: email) {
        Image(decorative: photo, scale: 1)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(.circle)
      } else if let initial = email?.first {
        Text(String(initial).uppercased())
          .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: size, height: size)
          .background(Color.blue.gradient, in: .circle)
      } else {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
      }
    }
    .accessibilityHidden(true)
  }
}

/// An inline message for errors and notices that belong next to the control they explain.
public struct InlineMessage: View {
  public enum Style {
    case error
    case warning
    case info

    var symbol: String {
      switch self {
      case .error: "exclamationmark.octagon.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .info: "info.circle.fill"
      }
    }

    var tint: Color {
      switch self {
      case .error: .red
      case .warning: .orange
      case .info: .blue
      }
    }
  }

  private let text: String
  private let style: Style

  public init(_ text: String, style: Style = .error) {
    self.text = text
    self.style = style
  }

  public var body: some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: style.symbol)
        .foregroundStyle(style.tint)
    }
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(style.tint.opacity(0.1), in: .rect(cornerRadius: Radius.inset, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Background

/// The grouped background with a faint glow of the current status color at the top.
public struct AmbientBackground: View {
  private let tint: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  public init(tint: Color) {
    self.tint = tint
  }

  public var body: some View {
    LinearGradient(
      stops: [.init(color: tint.opacity(colorScheme == .dark ? 0.08 : 0.10), location: 0), .init(color: .clear, location: 0.35)],
      startPoint: .top,
      endPoint: .bottom
    )
    .background(Self.base)
    .ignoresSafeArea()
    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: tint)
    .accessibilityHidden(true)
  }

  #if os(iOS)
    private static let base = Color(uiColor: .systemGroupedBackground)
  #else
    private static let base = Color(nsColor: .windowBackgroundColor)
  #endif
}

// MARK: - Settings groups

/// A titled glass card of setting rows, as used on the dashboard and the Mac settings.
public struct SettingsGroup<Content: View>: View {

  private let title: LocalizedStringKey
  private let footer: LocalizedStringKey?
  private let content: Content
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = SettingLabel.baseIconSize

  #if os(iOS)
    private static var spacing: CGFloat { 10 }
  #else
    private static var spacing: CGFloat { 8 }
  #endif

  public init(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Self.spacing) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.leading, 6)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        Group(subviews: content) { rows in
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
              Divider()
                .padding(.leading, SettingRow<EmptyView>.horizontalPadding + SettingLabel.textInset(iconSize: iconSize))
            }
            row
          }
        }
      }
      .glassCard()
      if let footer {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
      }
    }
  }
}

/// One row in a `SettingsGroup`: a colorful, descriptive label and its control.
public struct SettingRow<Control: View>: View {
  static var horizontalPadding: CGFloat { 16 }
  #if os(iOS)
    static var verticalPadding: CGFloat { 14 }
  #else
    static var verticalPadding: CGFloat { 12 }
  #endif

  private let label: SettingLabel
  private let control: Control
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = SettingLabel.baseIconSize

  public init(
    _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, symbol: String, colors: [Color],
    @ViewBuilder control: () -> Control
  ) {
    label = SettingLabel(title, detail: detail, symbol: symbol, colors: colors)
    self.control = control()
  }

  public var body: some View {
    let isAccessibility = dynamicTypeSize.isAccessibilitySize
    let layout =
      isAccessibility
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(spacing: 12))
    layout {
      label
        .frame(maxWidth: .infinity, alignment: .leading)
      control
        .labelsHidden()
        .padding(.leading, isAccessibility ? SettingLabel.textInset(iconSize: iconSize) : 0)
        .frame(maxWidth: isAccessibility ? .infinity : nil, alignment: .leading)
    }
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.vertical, Self.verticalPadding)
    .accessibilityElement(children: .contain)
  }
}
