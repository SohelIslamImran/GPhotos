import SwiftUI
import WidgetKit

/// A memory or person photo filling the widget, with its title over a soft shade, as in
/// Photos. Shared by the widget extensions and the app's widget gallery.
public struct PhotoWidgetView: View {
  let set: WidgetPhotoSet?
  let photo: WidgetPhoto?
  let family: WidgetFamily
  let emptyMessage: String
  let directory: URL

  public init(
    set: WidgetPhotoSet?, photo: WidgetPhoto?, family: WidgetFamily, emptyMessage: String,
    directory: URL = WidgetStore.directory
  ) {
    self.set = set
    self.photo = photo
    self.family = family
    self.emptyMessage = emptyMessage
    self.directory = directory
  }

  public var body: some View {
    if let set, let photo, let image = WidgetStore.image(photo, maxPixel: maxPixel, in: directory) {
      GeometryReader { proxy in
        let frame = Self.fill(
          CGSize(width: image.width, height: image.height), in: proxy.size,
          focus: CGPoint(x: photo.focusX ?? 0.5, y: photo.focusY ?? 0.5), keepsFocusHigh: photo.focusY != nil)
        Image(decorative: image, scale: 1)
          .resizable()
          .widgetAccentedRenderingMode(.desaturated)
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
      }
      .clipped()
      .overlay(alignment: .bottomLeading) { caption(set: set, photo: photo) }
      .widgetURL(WidgetLink.photo(photo.itemID).url)
    } else {
      WidgetEmptyView(symbol: set?.kind == .person ? "person.crop.square" : "photo.on.rectangle.angled", message: emptyMessage)
    }
  }

  private var maxPixel: Int { family == .systemSmall ? 600 : WidgetPublisher.imageSide }

  /// Where an image filling `container` goes so `focus` (normalized, top left origin)
  /// stays in view: centred, or a little above centre for a face, as a portrait is framed.
  nonisolated static func fill(_ image: CGSize, in container: CGSize, focus: CGPoint, keepsFocusHigh: Bool) -> CGRect {
    guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: container) }
    let scale = max(container.width / image.width, container.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    let target = CGPoint(x: container.width / 2, y: container.height * (keepsFocusHigh ? 0.42 : 0.5))
    let x = min(0, max(container.width - size.width, target.x - focus.x * size.width))
    let y = min(0, max(container.height - size.height, target.y - focus.y * size.height))
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  private func caption(set: WidgetPhotoSet, photo: WidgetPhoto) -> some View {
    let subtitle =
      switch set.kind {
      case .featured, .person: photo.date.formatted(.dateTime.day().month(.abbreviated).year())
      case .onThisDay, .trip: set.subtitle
      }
    return VStack(alignment: .leading, spacing: 1) {
      if !set.title.isEmpty {
        Text(set.title)
          .font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline)
          .lineLimit(1)
      }
      if !subtitle.isEmpty {
        Text(subtitle)
          .font(family == .systemSmall ? .caption2 : .caption)
          .opacity(0.9)
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    .padding(family == .systemSmall ? 12 : 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .bottom) {
      LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        .padding(.top, -24)
    }
  }
}

/// Shown until the app has picked photos, or when there are none to show.
public struct WidgetEmptyView: View {
  let symbol: String
  let message: String

  public init(symbol: String, message: String) {
    self.symbol = symbol
    self.message = message
  }

  public var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(.secondary)
        .widgetAccentable()
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The backup at a glance: its status, how much is backed up and when that was checked.
public struct BackupWidgetView: View {
  let snapshot: WidgetBackupSnapshot?
  let family: WidgetFamily

  public init(snapshot: WidgetBackupSnapshot?, family: WidgetFamily) {
    self.snapshot = snapshot
    self.family = family
  }

  public var body: some View {
    content.widgetURL(WidgetLink.backup.url)
  }

  @ViewBuilder private var content: some View {
    switch family {
    #if os(iOS)
      case .accessoryInline:
        Label(title, systemImage: symbol)
      case .accessoryCircular:
        ZStack {
          AccessoryWidgetBackground()
          VStack(spacing: 1) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
            if let count = snapshot?.backedUpCount, snapshot?.isSignedIn == true {
              Text(count, format: .number.notation(.compactName)).font(.caption2).minimumScaleFactor(0.6)
            }
          }
        }
        .widgetAccentable()
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 1) {
          Label(title, systemImage: symbol)
            .font(.headline)
            .widgetAccentable()
          Text(countText).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    #endif
    default:
      VStack(alignment: .leading, spacing: 0) {
        Image(systemName: symbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(tone, in: .circle)
          .widgetAccentable()
        Spacer(minLength: 8)
        Text(title)
          .font(.headline)
          .lineLimit(2)
          .minimumScaleFactor(0.85)
        Text(countText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var title: String {
    guard let snapshot else { return String(localized: "Open GPhotos") }
    return snapshot.isSignedIn ? snapshot.title : String(localized: "Sign In to Back Up")
  }

  private var symbol: String { snapshot?.symbol ?? "icloud.and.arrow.up" }

  private var tone: Color {
    (snapshot.flatMap { BackupStatus.Tone(rawValue: $0.tone) } ?? .accent).color
  }

  private var countText: String {
    guard let snapshot, snapshot.isSignedIn else { return String(localized: "Original quality") }
    return String(localized: "\(snapshot.backedUpCount.formatted()) backed up")
  }
}

#if DEBUG
  /// Every widget at its real sizes with the data the app last published, for review in
  /// the app (`-UIScreen widgets`) without adding widgets to the Home Screen or desktop.
  public struct WidgetGallery: View {
    @State private var photos = WidgetStore.photos()
    @State private var backup = WidgetStore.backup()

    public init() {}

    public var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach((photos?.memories ?? []) + (photos?.people.prefix(2) ?? [])) { set in
            Text("\(set.kind.rawValue): \(set.title) · \(set.photos.count) photos").font(.headline)
            HStack(alignment: .top, spacing: 16) {
              tile(width: 170, height: 170) {
                PhotoWidgetView(set: set, photo: set.photos.first, family: .systemSmall, emptyMessage: "")
              }
              tile(width: 364, height: 170) {
                PhotoWidgetView(set: set, photo: set.photos.dropFirst().first ?? set.photos.first, family: .systemMedium, emptyMessage: "")
              }
              tile(width: 364, height: 382) {
                PhotoWidgetView(set: set, photo: set.photos.last, family: .systemLarge, emptyMessage: "")
              }
            }
          }
          Text("Backup").font(.headline)
          HStack(spacing: 16) {
            tile(width: 170, height: 170) { BackupWidgetView(snapshot: backup, family: .systemSmall).padding(16) }
            tile(width: 170, height: 170) { BackupWidgetView(snapshot: nil, family: .systemSmall).padding(16) }
            tile(width: 170, height: 170) {
              PhotoWidgetView(set: nil, photo: nil, family: .systemSmall, emptyMessage: "Open GPhotos to see your memories.")
            }
          }
        }
        .padding(24)
      }
    }

    private func tile<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
      content()
        .frame(width: width, height: height)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }
  }
#endif
