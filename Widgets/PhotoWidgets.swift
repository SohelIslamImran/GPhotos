import AppIntents
import GPhotosKit
import SwiftUI
import WidgetKit

/// One hour of a photo widget: the set and photo it shows then.
struct PhotoEntry: TimelineEntry {
  let date: Date
  let set: WidgetPhotoSet?
  let photo: WidgetPhoto?
}

private let photoFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
/// Twelve hours of photos per timeline; WidgetKit asks again after that.
private let timelineHours = 12

/// On This Day, trips and featured photos, a different one every hour, as Photos does.
struct MemoriesWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetStore.memoriesKind, provider: MemoriesProvider()) { entry in
      PhotoWidgetEntryView(entry: entry, emptyMessage: String(localized: "Open GPhotos to see your memories."))
    }
    .configurationDisplayName("Memories")
    .description("Photos from this day in past years, trips and your best shots, from your device and Google Photos.")
    .supportedFamilies(photoFamilies)
    .contentMarginsDisabled()
  }
}

struct MemoriesProvider: TimelineProvider {
  func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: Date(), set: nil, photo: nil) }

  func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) {
    completion(Self.entries(from: Date(), hours: 1).first ?? placeholder(in: context))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
    let entries = Self.entries(from: Date(), hours: timelineHours)
    completion(Timeline(entries: entries, policy: .after((entries.last?.date ?? Date()).addingTimeInterval(3_600))))
  }

  /// Every photo of every memory in turn. On This Day belongs to the day the app picked
  /// it; on later days (before the app runs again) the other memories show instead.
  static func entries(from date: Date, hours: Int) -> [PhotoEntry] {
    let snapshot = WidgetStore.photos()
    return WidgetRotation.hours(from: date, count: hours).map { hour in
      let sets = (snapshot?.memories ?? []).filter { set in
        set.kind != .onThisDay || Calendar.current.isDate(snapshot?.generatedAt ?? .distantPast, inSameDayAs: hour)
      }
      let pairs = sets.flatMap { set in set.photos.map { (set, $0) } }
      guard !pairs.isEmpty else { return PhotoEntry(date: hour, set: nil, photo: nil) }
      let (set, photo) = pairs[WidgetRotation.index(count: pairs.count, at: hour)]
      return PhotoEntry(date: hour, set: set, photo: photo)
    }
  }
}

/// A person's photos; the widget's settings choose who (the most photographed by default).
struct PeopleWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: WidgetStore.peopleKind, intent: SelectPersonIntent.self, provider: PeopleProvider()) {
      entry in
      PhotoWidgetEntryView(entry: entry, emptyMessage: String(localized: "People appear once your photos are indexed."))
    }
    .configurationDisplayName("People")
    .description("Photos of someone you choose.")
    .supportedFamilies(photoFamilies)
    .contentMarginsDisabled()
  }
}

struct PeopleProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: Date(), set: nil, photo: nil) }

  func snapshot(for configuration: SelectPersonIntent, in context: Context) async -> PhotoEntry {
    Self.entries(for: configuration.person?.id, from: Date(), hours: 1).first ?? placeholder(in: context)
  }

  func timeline(for configuration: SelectPersonIntent, in context: Context) async -> Timeline<PhotoEntry> {
    let entries = Self.entries(for: configuration.person?.id, from: Date(), hours: timelineHours)
    return Timeline(entries: entries, policy: .after((entries.last?.date ?? Date()).addingTimeInterval(3_600)))
  }

  static func entries(for personID: String?, from date: Date, hours: Int) -> [PhotoEntry] {
    let people = WidgetStore.photos()?.people ?? []
    let set = people.first { $0.id == personID } ?? people.first
    return WidgetRotation.hours(from: date, count: hours).map { hour in
      guard let set, !set.photos.isEmpty else { return PhotoEntry(date: hour, set: set, photo: nil) }
      return PhotoEntry(date: hour, set: set, photo: set.photos[WidgetRotation.index(count: set.photos.count, at: hour)])
    }
  }
}

struct PhotoWidgetEntryView: View {
  let entry: PhotoEntry
  let emptyMessage: String
  @Environment(\.widgetFamily) private var family

  var body: some View {
    PhotoWidgetView(set: entry.set, photo: entry.photo, family: family, emptyMessage: emptyMessage)
      .containerBackground(for: .widget) { Color(white: 0.12) }
  }
}

// MARK: Choosing a person

struct SelectPersonIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Choose a Person"
  static let description = IntentDescription("Choose whose photos the widget shows.")

  @Parameter(title: "Person")
  var person: WidgetPersonEntity?
}

/// Someone from the People the app last published.
struct WidgetPersonEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
  static let defaultQuery = WidgetPersonQuery()

  let id: String
  let name: String
  let subtitle: String
  let imageFile: String?

  var displayRepresentation: DisplayRepresentation {
    let image = imageFile.flatMap { try? Data(contentsOf: WidgetStore.directory.appendingPathComponent($0)) }
    return DisplayRepresentation(
      title: "\(name)", subtitle: "\(subtitle)", image: image.map { DisplayRepresentation.Image(data: $0) })
  }

  init(_ set: WidgetPhotoSet) {
    id = set.id
    name = set.title.isEmpty ? String(localized: "Unnamed") : set.title
    subtitle = set.subtitle
    imageFile = set.photos.first?.file
  }
}

struct WidgetPersonQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [WidgetPersonEntity] {
    people().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [WidgetPersonEntity] { people() }

  private func people() -> [WidgetPersonEntity] {
    (WidgetStore.photos()?.people ?? []).map(WidgetPersonEntity.init)
  }
}

// MARK: Backup

/// The backup status, on the Home Screen, the desktop and (on iPhone) the Lock Screen.
struct BackupStatusWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetStore.backupKind, provider: BackupProvider()) { entry in
      BackupWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Backup")
    .description("Whether your photos are backed up to Google Photos.")
    .supportedFamilies(Self.families)
  }

  private static var families: [WidgetFamily] {
    #if os(iOS)
      [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
      [.systemSmall]
    #endif
  }
}

struct BackupEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetBackupSnapshot?
}

struct BackupProvider: TimelineProvider {
  func placeholder(in context: Context) -> BackupEntry { BackupEntry(date: Date(), snapshot: nil) }

  func getSnapshot(in context: Context, completion: @escaping (BackupEntry) -> Void) {
    completion(BackupEntry(date: Date(), snapshot: WidgetStore.backup()))
  }

  /// The app reloads this when the status changes; the hourly refresh only catches up.
  func getTimeline(in context: Context, completion: @escaping (Timeline<BackupEntry>) -> Void) {
    let entry = BackupEntry(date: Date(), snapshot: WidgetStore.backup())
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3_600))))
  }
}

struct BackupWidgetEntryView: View {
  let entry: BackupEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    BackupWidgetView(snapshot: entry.snapshot, family: family)
      .containerBackground(.fill.tertiary, for: .widget)
  }
}
