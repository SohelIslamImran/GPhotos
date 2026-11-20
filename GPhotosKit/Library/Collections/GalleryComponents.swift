import SwiftUI

#if os(macOS)

  /// Building blocks for the Mac's browsing pages (Collections, Search): titled sections of
  /// tiles and rows that respond to the pointer, as in Photos and Music on the Mac.

  /// A titled section of a scrolling page, with an optional link at the trailing end.
  struct GallerySection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let content: Content
    let accessory: Accessory

    init(
      _ title: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
      @ViewBuilder content: () -> Content
    ) {
      self.title = title
      self.accessory = accessory()
      self.content = content()
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          accessory
            .buttonStyle(.link)
            .font(.callout)
        }
        content
      }
    }
  }

  /// Lifts a tile a little under the pointer, as Photos and Music do on the Mac.
  struct HoverLift: ViewModifier {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      content
        .scaleEffect(isHovered && !reduceMotion ? 1.025 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: isHovered ? 10 : 0, y: isHovered ? 4 : 0)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
  }

  extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
  }

  /// One row-like tile: a tinted symbol, a title, a count, and a chevron, on a neutral
  /// rounded surface that darkens under the pointer.
  struct GalleryRow: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var count: Int?
    @State private var isHovered = false

    var body: some View {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.body.weight(.medium))
          .foregroundStyle(tint)
          .frame(width: 22)
          .accessibilityHidden(true)
        Text(title)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let count {
          Text(count, format: .number)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.forward")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)
      .background(
        isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary),
        in: .rect(cornerRadius: 10, style: .continuous)
      )
      .contentShape(.rect(cornerRadius: 10, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(.smooth(duration: 0.15), value: isHovered)
      .accessibilityElement(children: .combine)
    }
  }

  /// Columns for a grid of `GalleryRow`s.
  let galleryRowColumns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 10)]

  /// A photo cover with a title and count under it, for albums and similar collections.
  struct GalleryCover: View {
    let title: String
    let count: Int?
    let thumbnailID: String?
    var source: any ThumbnailSource = PhotoKitImageSource.shared
    var symbol = "rectangle.stack"

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        Color.clear
          .aspectRatio(1, contentMode: .fit)
          .overlay {
            if thumbnailID != nil {
              LibraryThumbnail(id: thumbnailID, bucket: .medium, source: source)
            } else {
              Rectangle().fill(.fill.tertiary)
                .overlay {
                  Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
          }
          .clipShape(.rect(cornerRadius: 12, style: .continuous))
          .hoverLift()
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.callout.weight(.medium)).lineLimit(1)
          if let count {
            Text(count, format: .number).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
      }
      .contentShape(.rect)
      .accessibilityElement(children: .combine)
    }
  }

  /// Columns for a grid of `GalleryCover`s.
  let galleryCoverColumns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18, alignment: .top)]

  extension View {
    /// The padding and width limit every browsing page shares, so content doesn't stretch
    /// across a very wide window.
    func galleryPage() -> some View {
      padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .frame(maxWidth: 1240, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
  }
#endif
