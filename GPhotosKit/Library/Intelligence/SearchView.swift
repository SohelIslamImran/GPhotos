import MapKit
import Photos
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Where Search navigates.
/// A list of item ids passed between screens, compared by identity so navigation
/// doesn't hash tens of thousands of strings.
public final class ItemIDs: Hashable, Sendable {
  public let values: [String]

  public init(_ values: [String]) {
    self.values = values
  }

  public static func == (lhs: ItemIDs, rhs: ItemIDs) -> Bool { lhs === rhs }
  public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public enum SearchRoute: Hashable {
  case results(title: String, ids: ItemIDs)
  /// A Vision label, resolved to its photos when opened.
  case label(String)
  case utility
  case people
  case person(id: Int64, name: String?)
  case similar
  case cloudDuplicates
  case places
}

extension View {
  /// The title large on the left beside the back button, as the tabs' first screens have
  /// it (iPhone); the Mac's window title is left alone.
  func largeInlineTitle() -> some View {
    #if os(iOS)
      toolbarTitleDisplayMode(.inlineLarge)
    #else
      self
    #endif
  }
}

/// The prompt for the search field that drives `SearchView`.
public let searchPrompt = Text("Photos, places, text, people")

/// The Search tab: free-text search over the on-device index, plus Memories, People,
/// categories and cleanup tools when the field is empty. Put it in a `NavigationStack`.
public struct SearchView: View {
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  let cloud: CloudLibrary?
  let records: [TransferRecord]
  /// Owned by the screen holding the search field: on iPhone the tab bar's (applied to
  /// the `TabView`), on the Mac the window's toolbar.
  @Binding var query: String
  @State private var results: [String]?
  @State private var resolvedQuery = ""
  @AppStorage("recentLibrarySearches") private var recentSearches = ""
  /// The search field has focus: typing shows suggestions, and Return or a suggestion
  /// leaves it and shows the results.
  private let isEditing: Bool
  private let finishSearch: () -> Void
  @State private var categories: [SearchCategory] = []
  @State private var typedSuggestions: [SearchSuggestion] = []
  @State private var people: [Person] = []
  @State private var memories: [Memory] = []
  @State private var isVisible = false
  @State private var lastDiscoveryRevision = -1
  @State private var lastMemoriesToken = -1
  /// The Search tab's stack. The people, memories and things tapped sit several to a list
  /// row, where links would all open at once, so buttons push them here; a destination of
  /// its own (`navigationDestination(item:)`) pushed itself again whenever the screen it
  /// showed pushed another.
  @Binding private var path: NavigationPath
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct DiscoveryTrigger: Equatable {
    let visible: Bool
    let revision: Int
  }

  private struct MemoriesTrigger: Equatable {
    let visible: Bool
    let reloadToken: Int
  }

  public init(
    library: UnifiedLibraryModel, indexer: LibraryIndexer, cloud: CloudLibrary?, records: [TransferRecord],
    query: Binding<String>, path: Binding<NavigationPath>, isEditing: Bool = false,
    finishSearch: @escaping () -> Void = {}
  ) {
    self._path = path
    self.isEditing = isEditing
    self.finishSearch = finishSearch
    self._query = query
    self.library = library
    self.indexer = indexer
    self.cloud = cloud
    self.records = records
  }

  public var body: some View {
    Group {
      if !searchText.isEmpty {
        if isEditing {
          suggestions.transition(.opacity)
        } else if resolvedQuery == searchText, let results {
          ResultsGridView(
            title: String(localized: "Search"), library: library, ids: results, searchQuery: searchText
          )
          .transition(.opacity)
        } else {
          ProgressView("Searching")
        }
      } else {
        discovery.transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: searchText.isEmpty)
    .navigationTitle("Search")
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .task(id: isEditing) {
      // Cancel also leaves the field, and clears it just after: only a search that's
      // still there a moment later is kept.
      guard !isEditing else { return }
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      remember(searchText)
    }
    .task(id: query) {
      let text = searchText
      guard !text.isEmpty else {
        results = nil
        resolvedQuery = ""
        return
      }
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      let found = await matches(for: text)
      guard !Task.isCancelled else { return }
      results = found
      resolvedQuery = text
      // A search the user stays on is one Siri can learn to suggest.
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      if !found.isEmpty { SiriLibrary.donateSearch(text) }
    }
    .task(id: DiscoveryTrigger(visible: isVisible, revision: indexer.contentRevision)) {
      guard isVisible, lastDiscoveryRevision != indexer.contentRevision else { return }
      let revision = indexer.contentRevision
      await loadDiscovery()
      if !Task.isCancelled { lastDiscoveryRevision = revision }
    }
    .task(id: query) {
      let text = searchText
      guard !text.isEmpty else {
        typedSuggestions = []
        return
      }
      do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
      let found = await indexer.suggestions(for: text)
      if !Task.isCancelled { typedSuggestions = found }
    }
    .task {
      #if DEBUG
        if let preset = UserDefaults.standard.string(forKey: "UISearchQuery") { query = preset }
      #endif
      // Search works before the Library tab has been opened.
      guard !library.isLoaded else { return }
      library.setCloudLibrary(cloud)
      await library.start(records: records)
    }
    .task(id: MemoriesTrigger(visible: isVisible, reloadToken: library.reloadToken)) {
      guard isVisible else { return }
      indexer.update(from: library)
      guard lastMemoriesToken != library.reloadToken else { return }
      let token = library.reloadToken
      // A sync reloads the library every few seconds; Memories follow once it pauses.
      if !memories.isEmpty {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
      let found = await Memory.find(in: library)
      if !Task.isCancelled {
        memories = found
        lastMemoriesToken = token
      }
    }
    // Places' pins push collection routes.
    .navigationDestination(for: CollectionRoute.self) { route in
      if case .place(let ids, let latitude, let longitude) = route {
        PlaceLibraryScreen(ids: ids.values, latitude: latitude, longitude: longitude).largeInlineTitle()
      }
    }
    .navigationDestination(for: SearchRoute.self) { destination(for: $0).largeInlineTitle() }
  }

  @ViewBuilder
  private func destination(for route: SearchRoute) -> some View {
    switch route {
    case .results(let title, let ids): ResultsGridView(title: title, library: library, ids: ids.values)
    case .label(let label):
      IndexedResults(title: SearchVocabulary.displayName(label), library: library) {
        (try? await indexer.store.ids(withLabel: label)) ?? []
      }
    case .utility:
      IndexedResults(title: String(localized: "Screenshots & Documents"), library: library) {
        (try? await indexer.store.utilityIDs()) ?? []
      }
    case .people: PeopleView(library: library, indexer: indexer)
    case .person(let id, let name): PersonView(library: library, indexer: indexer, personID: id, name: name)
    case .similar: SimilarPhotosView(library: library, indexer: indexer)
    case .cloudDuplicates: if let cloud { CloudDuplicatesView(library: library, cloud: cloud) }
    case .places: PlacesView(cloud: cloud, records: records)
    }
  }

  /// Dates, videos and favorites in the words narrow the results ("beach videos 2024"), as
  /// they do for Siri. Other searches, and words that only look like a filter (a person
  /// named May), use plain matching.
  private func matches(for text: String) async -> [String] {
    await Self.matches(
      for: text,
      named: { (try? await indexer.store.search(personNamed: text))?.isEmpty == false },
      structured: { completing in await SiriLibrary.shared.search(text, limit: .max, completingLastWord: completing) },
      plain: { await indexer.search(text) })
  }

  static func matches(
    for text: String, named: () async -> Bool, structured: (Bool) async -> [String], plain: () async -> [String]
  ) async -> [String] {
    let parsed = SiriSearchQuery(text)
    guard parsed.period != nil || parsed.videosOnly || parsed.favoritesOnly, !(await named()) else {
      return await plain()
    }
    let found = await structured(text.last?.isWhitespace != true)
    if found.isEmpty, !parsed.terms.isEmpty { return await plain() }
    return found
  }

  private func loadDiscovery() async {
    let text = searchText
    if !text.isEmpty {
      let found = await matches(for: text)
      guard !Task.isCancelled else { return }
      if text == searchText {
        results = found
        resolvedQuery = text
      }
    }
    categories = await indexer.categories()
    people = (try? await indexer.store.people()) ?? []
  }

  private var discovery: some View {
    List {
      recentSection
      peopleSection
      memoriesSection
      placesSection
      thingsSection
      utilitiesSection
      Section {
      } footer: {
        if let status = statusText {
          Label(status, systemImage: "sparkle.magnifyingglass")
        } else {
          Text("Search your photos by people, places, things, or text.")
        }
      }
    }
    .listStyle(.inset)
    .textCase(nil)
    .scrollDismissesKeyboard(.interactively)
    #if os(iOS)
      // The floating search field covers the end of the list otherwise.
      .contentMargins(.bottom, 72, for: .scrollContent)
    #else
      .safeAreaPadding(.bottom, 16)
    #endif
  }

  /// A section's title as its first row: a list's own headers stay pinned under the bar,
  /// over the photos scrolling past.
  private func sectionTitle(
    _ title: LocalizedStringKey, @ViewBuilder trailing: () -> some View = { EmptyView() }
  ) -> some View {
    HStack {
      Text(title).font(.title2.bold())
      Spacer()
      trailing()
    }
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 2, trailing: 16))
    .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private var peopleSection: some View {
    if !people.isEmpty {
      Section {
        sectionTitle("People") { Button("See All") { path.append(SearchRoute.people) }.font(.subheadline).buttonStyle(.borderless) }
        ScrollView(.horizontal) {
          LazyHStack(spacing: 14) {
            ForEach(people.prefix(16)) { person in
              Button {
                path.append(SearchRoute.person(id: person.id, name: person.name))
              } label: {
                PersonChip(library: library, person: person, side: 72)
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }
    }
  }

  @ViewBuilder
  private var memoriesSection: some View {
    if !memories.isEmpty {
      Section {
        sectionTitle("Memories")
        ScrollView(.horizontal) {
          LazyHStack(spacing: 12) {
            ForEach(memories) { memory in
              Button {
                path.append(SearchRoute.results(title: memory.title, ids: memory.idList))
              } label: {
                MemoryCard(library: library, memory: memory)
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }
    }
  }

  @ViewBuilder
  private var placesSection: some View {
    Section {
      sectionTitle("Places")
      NavigationLink(value: SearchRoute.places) {
        PlacesPreviewMap(memories: memories)
          .frame(height: 160)
          .overlay(alignment: .bottomLeading) {
            Label("Explore the Map", systemImage: "map")
              .font(.headline).padding(10).glassEffect(in: .capsule).padding(12)
          }
          .clipShape(.rect(cornerRadius: 18))
          .allowsHitTesting(false)
      }
      .buttonStyle(.plain)
      .navigationLinkIndicatorVisibility(.hidden)
      .accessibilityLabel("Explore Places")
      .listRowSeparator(.hidden)
    }
  }

  @ViewBuilder
  private var thingsSection: some View {
    if !categories.isEmpty {
      Section {
        sectionTitle("Things")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
          ForEach(categories) { category in
            CategoryTile(library: library, category: category) { path.append(SearchRoute.label(category.label)) }
          }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }
    }
  }

  @ViewBuilder
  private var utilitiesSection: some View {
    Section {
      sectionTitle("Media Types & Utilities")
      NavigationLink(value: SearchRoute.similar) {
        Label("Similar Photos", systemImage: "square.on.square")
      }
      if cloud != nil {
        NavigationLink(value: SearchRoute.cloudDuplicates) {
          Label("Duplicates in Google Photos", systemImage: "doc.on.doc")
        }
      }
      UtilityLink(indexer: indexer)
    }
  }

  @ViewBuilder
  private var recentSection: some View {
    if !recentQueries.isEmpty {
      Section {
        sectionTitle("Recent Searches") {
          Button("Clear") { recentSearches = "" }.font(.subheadline).buttonStyle(.borderless)
        }
        ForEach(recentQueries, id: \.self) { text in
          Button {
            submitSearch(text)
          } label: {
            Label(text, systemImage: "clock").foregroundStyle(.primary)
          }
          .contextMenu {
            Button("Remove", role: .destructive) {
              recentSearches = recentQueries.filter { $0 != text }.joined(separator: "\n")
            }
          }
        }
      }
    }
  }

  private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var recentQueries: [String] { recentSearches.split(separator: "\n").map(String.init) }

  private func remember(_ text: String) {
    guard !text.isEmpty else { return }
    recentSearches = ([text] + recentQueries.filter { $0 != text }).prefix(8).joined(separator: "\n")
  }

  private func submitSearch(_ text: String) {
    guard !text.isEmpty else { return }
    query = text
    remember(text)
    finishSearch()
  }

  private struct ResolvedSuggestions {
    var people: [Person] = []
    var categories: [SearchCategory] = []
    var words: [SearchSuggestion] = []
  }

  /// Resolves typed suggestions into people, categories and word rows once per render using
  /// dictionary/set lookups instead of repeated quadratic scans.
  private func resolveSuggestions() -> ResolvedSuggestions {
    var peopleByName: [String: Person] = [:]
    for person in people {
      if let name = person.name, peopleByName[name] == nil { peopleByName[name] = person }
    }
    var categoriesByLabel: [String: SearchCategory] = [:]
    for category in categories where categoriesByLabel[category.label] == nil {
      categoriesByLabel[category.label] = category
    }

    var matchedPeople: [Person] = []
    var matchedCategories: [SearchCategory] = []
    var shownPeopleNames = Set<String>()
    var shownCategoryLabels = Set<String>()
    for suggestion in typedSuggestions {
      switch suggestion.kind {
      case .person:
        if let person = peopleByName[suggestion.query] {
          matchedPeople.append(person)
          shownPeopleNames.insert(suggestion.query)
        }
      case .category:
        let canonical = SearchVocabulary.canonical(suggestion.query)
        if let category = categoriesByLabel[canonical] {
          matchedCategories.append(category)
          shownCategoryLabels.insert(category.label)
        }
      case .metadata, .text:
        break
      }
    }

    let words = typedSuggestions.filter { suggestion in
      // The first row already searches for exactly what was typed.
      guard suggestion.query.localizedCaseInsensitiveCompare(searchText) != .orderedSame else { return false }
      return switch suggestion.kind {
      case .metadata, .text: true
      case .category: !shownCategoryLabels.contains(SearchVocabulary.canonical(suggestion.query))
      case .person: !shownPeopleNames.contains(suggestion.query)
      }
    }
    return ResolvedSuggestions(people: matchedPeople, categories: matchedCategories, words: words)
  }

  private var suggestions: some View {
    let resolved = resolveSuggestions()
    return List {
      Section {
        Button {
          submitSearch(searchText)
        } label: {
          suggestionRow(
            title: searchText, subtitle: String(localized: "Search All Photos"), icon: "magnifyingglass",
            count: resolvedQuery == searchText ? results?.count : nil)
        }
        .foregroundStyle(.primary)
      }
      if !resolved.people.isEmpty {
        Section("People") {
          ForEach(resolved.people) { person in
            NavigationLink(value: SearchRoute.person(id: person.id, name: person.name)) {
              HStack(spacing: 12) {
                PersonChip(library: library, person: person, side: 44, showsCaption: false)
                Text(person.name ?? String(localized: "Unnamed Person"))
                Spacer()
                Text(person.faceCount, format: .number).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      if !resolved.categories.isEmpty {
        Section("Things") {
          ForEach(resolved.categories.prefix(8)) { category in
            NavigationLink(value: SearchRoute.label(category.label)) {
              HStack(spacing: 12) {
                LibraryThumbnail(
                  id: library.position(ofIndexID: category.sampleID).map(library.itemID(at:)),
                  bucket: .small, source: library.thumbnailSource
                )
                .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                Text(category.displayName)
                Spacer()
                Text(category.count, format: .number).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      if !resolved.words.isEmpty {
        Section("Suggestions") {
          ForEach(resolved.words) { suggestion in
            Button {
              submitSearch(suggestion.query)
            } label: {
              suggestionRow(
                title: suggestion.title, subtitle: Self.subtitle(suggestion.kind), icon: Self.icon(suggestion.kind),
                count: suggestion.count)
            }
            .foregroundStyle(.primary)
          }
        }
      }
    }
    .listStyle(.inset)
    .textCase(nil)
    // Leaving the field shows the results, so scrolling suggestions must keep it.
    .scrollDismissesKeyboard(.never)
    #if os(iOS)
      // The floating search field covers the end of the list otherwise.
      .contentMargins(.bottom, 72, for: .scrollContent)
    #else
      .safeAreaPadding(.bottom, 16)
    #endif
  }

  private static func icon(_ kind: SearchSuggestion.Kind) -> String {
    switch kind {
    case .person: "person.crop.circle"
    case .category: "tag"
    case .metadata: "info.circle"
    case .text: "text.viewfinder"
    }
  }

  private static func subtitle(_ kind: SearchSuggestion.Kind) -> String {
    switch kind {
    case .person: String(localized: "Person")
    case .category: String(localized: "Thing")
    case .metadata: String(localized: "Details")
    case .text: String(localized: "Text in Photos")
    }
  }

  private func suggestionRow(title: String, subtitle: String, icon: String, count: Int?) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
        .background(.quaternary, in: .rect(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let count { Text(count, format: .number).foregroundStyle(.secondary) }
    }
  }

  private var statusText: String? {
    switch indexer.state {
    case .idle: nil
    case .indexing(let done, let total):
      String(localized: "Search is being prepared. \(done.formatted()) of \(total.formatted()) photos.")
    case .paused(let reason): reason
    }
  }
}

/// Static map preview rendered asynchronously by `MKMapSnapshotter` so the Search discovery
/// list doesn't keep a live Metal `MKMapView` alive on every visit.
private struct PlacesPreviewMap: View {
  let memories: [Memory]
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @State private var width: CGFloat = 0
  @State private var image: CGImage?

  private struct SnapshotKey: Hashable {
    let widthBucket: Int
    let scale: Int
    let isDark: Bool
    let coords: [Int]
  }

  private var tripPoints: [PlacePoint] {
    memories.compactMap { memory in
      guard case .trip(let latitude, let longitude) = memory.kind else { return nil }
      return PlacePoint(id: memory.id, latitude: latitude, longitude: longitude)
    }
  }

  private var snapshotKey: SnapshotKey {
    let bucket = max(0, Int((width / 16).rounded()) * 16)
    var coords: [Int] = []
    coords.reserveCapacity(tripPoints.count * 2)
    for point in tripPoints {
      coords.append(Int((point.latitude * 100).rounded()))
      coords.append(Int((point.longitude * 100).rounded()))
    }
    return SnapshotKey(widthBucket: bucket, scale: Int(displayScale.rounded()), isDark: colorScheme == .dark, coords: coords)
  }

  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if let image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .scaledToFill()
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { newWidth in
      if abs(newWidth - width) >= 16 || (width == 0 && newWidth > 0) { width = newWidth }
    }
    .task(id: snapshotKey) {
      let key = snapshotKey
      guard key.widthBucket > 0 else { return }
      let cacheID = "\(key.widthBucket)|\(key.scale)|\(key.isDark ? "d" : "l")|\(key.coords)" as NSString
      if let cached = PlacesPreviewCache.shared.object(forKey: cacheID) {
        image = cached
        return
      }
      let rendered = await renderSnapshot(
        width: CGFloat(key.widthBucket), height: 160, scale: displayScale, isDark: key.isDark, points: tripPoints)
      guard !Task.isCancelled, let rendered else { return }
      PlacesPreviewCache.shared.setObject(rendered, forKey: cacheID, cost: rendered.bytesPerRow * rendered.height)
      image = rendered
    }
  }

  private func renderSnapshot(
    width: CGFloat, height: CGFloat, scale: CGFloat, isDark: Bool, points: [PlacePoint]
  ) async -> CGImage? {
    let options = MKMapSnapshotter.Options()
    options.size = CGSize(width: width, height: height)
    options.pointOfInterestFilter = .excludingAll
    if var region = PlaceClusters.region(containing: points) {
      region.span.latitudeDelta = max(region.span.latitudeDelta, 0.5)
      region.span.longitudeDelta = max(region.span.longitudeDelta, 0.5)
      options.region = region
    } else {
      options.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 140))
    }
    #if os(iOS)
      options.scale = scale
      options.traitCollection = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
    #else
      options.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    #endif
    let snapshotter = MKMapSnapshotter(options: options)
    let box = SnapshotterBox(snapshotter)
    let snapshot: MKMapSnapshotter.Snapshot
    do {
      snapshot = try await withTaskCancellationHandler {
        try await snapshotter.start()
      } onCancel: {
        box.cancel()
      }
    } catch {
      return nil
    }
    guard !Task.isCancelled else { return nil }
    #if os(iOS)
      guard let base = snapshot.image.cgImage else { return nil }
      let pixelScale = snapshot.image.scale
    #else
      guard let base = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
      let pixelScale = width > 0 ? CGFloat(base.width) / width : scale
    #endif
    guard !points.isEmpty else { return base }
    let pinCenters: [CGPoint] = points.map { point in
      let pt = snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
      #if os(iOS)
        return CGPoint(x: pt.x * pixelScale, y: CGFloat(base.height) - pt.y * pixelScale)
      #else
        return CGPoint(x: pt.x * pixelScale, y: pt.y * pixelScale)
      #endif
    }
    return await Task.detached(priority: .utility) {
      Self.drawPins(pinCenters, on: base, scale: pixelScale)
    }.value
  }

  private nonisolated static func drawPins(_ centers: [CGPoint], on base: CGImage, scale: CGFloat) -> CGImage? {
    let space = base.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return base }
    context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let radius = 6 * scale
    let stroke = 2 * scale
    let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    let pinFill = CGColor(colorSpace: p3, components: [0.95, 0.25, 0.22, 1]) ?? CGColor(red: 0.95, green: 0.25, blue: 0.22, alpha: 1)
    let ringColor = CGColor(gray: 1, alpha: 1)
    for center in centers {
      let outerSide = (radius + stroke) * 2
      let outer = CGRect(
        x: center.x - radius - stroke, y: center.y - radius - stroke, width: outerSide, height: outerSide)
      let inner = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
      context.setFillColor(ringColor)
      context.fillEllipse(in: outer)
      context.setFillColor(pinFill)
      context.fillEllipse(in: inner)
    }
    return context.makeImage() ?? base
  }
}

private final class SendableImageCache: @unchecked Sendable {
  private let cache = NSCache<NSString, CGImage>()

  init(countLimit: Int, totalCostLimit: Int) {
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
  }

  func object(forKey key: NSString) -> CGImage? { cache.object(forKey: key) }
  func setObject(_ image: CGImage, forKey key: NSString, cost: Int) { cache.setObject(image, forKey: key, cost: cost) }
  func removeAllObjects() { cache.removeAllObjects() }
}

private enum PlacesPreviewCache {
  static let shared = SendableImageCache(countLimit: 16, totalCostLimit: 16 * 1024 * 1024)
}

private final class SnapshotterBox: @unchecked Sendable {
  private let snapshotter: MKMapSnapshotter
  init(_ snapshotter: MKMapSnapshotter) { self.snapshotter = snapshotter }
  func cancel() { snapshotter.cancel() }
}

/// Screenshots, receipts and documents, found by the aesthetics model.
private struct UtilityLink: View {
  let indexer: LibraryIndexer
  @State private var count = 0
  @State private var isVisible = false
  @State private var loadedRevision = -1

  private struct Trigger: Equatable {
    let visible: Bool
    let revision: Int
  }

  var body: some View {
    NavigationLink(value: SearchRoute.utility) {
      LabeledContent {
        Text(count, format: .number)
      } label: {
        Label("Screenshots & Documents", systemImage: "doc.text.viewfinder")
      }
    }
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .task(id: Trigger(visible: isVisible, revision: indexer.contentRevision)) {
      guard isVisible, loadedRevision != indexer.contentRevision else { return }
      let revision = indexer.contentRevision
      let found = (try? await indexer.store.utilityCount()) ?? 0
      if !Task.isCancelled {
        count = found
        loadedRevision = revision
      }
    }
  }
}

/// Results resolved from the index when the screen opens.
private struct IndexedResults: View {
  let title: String
  let library: UnifiedLibraryModel
  let load: () async -> [String]
  @State private var ids: [String]?

  var body: some View {
    ResultsGridView(title: title, library: library, ids: ids)
      .task { ids = await load() }
  }
}

private struct CategoryTile: View {
  let library: UnifiedLibraryModel
  let category: SearchCategory
  let open: () -> Void

  var title: String { category.displayName }

  var body: some View {
    // A button, not a link: a list row holding several links opens all of them at once,
    // one screen on top of another.
    Button(action: open) {
      ZStack(alignment: .bottomLeading) {
        LibraryThumbnail(
          id: library.position(ofIndexID: category.sampleID).map(library.itemID(at:)), bucket: .medium,
          source: library.thumbnailSource)
        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1).padding(8)
      }
      .aspectRatio(1, contentMode: .fit)
      .clipShape(.rect(cornerRadius: 12))
      .contentShape(.rect(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("\(title), \(category.count) items"))
  }
}

// MARK: - Memories

/// On This Day and trips across the merged library.
struct Memory: Identifiable, Sendable, Hashable {
  enum Kind: Hashable, Sendable {
    case onThisDay(yearsAgo: Int)
    case trip(latitude: Double, longitude: Double)
  }

  let kind: Kind
  let idList: ItemIDs
  let date: Date
  var id: String { "\(kind)-\(idList.values.first ?? "")" }

  var title: String {
    switch kind {
    case .onThisDay(let years): ProductCopy.inflected("^[\(years) year](inflect: true) ago")
    case .trip: date.formatted(.dateTime.month(.wide).year())
    }
  }

  /// Runs off the main actor from the library's unfiltered snapshot: at 100,000 items the
  /// moments alone are a large array, and active Library filters must not hide memories.
  @MainActor
  static func find(in library: UnifiedLibraryModel) async -> [Memory] {
    let snapshot = library.indexSnapshot()
    return await Task.detached(priority: .utility) {
      let unfiltered = snapshot.unfiltered()
      let moments = unfiltered.moments()
      let days = MemoryFinder.onThisDay(moments, today: Date())
      let trips = MemoryFinder.trips(moments)
      let currentYear = Calendar.current.component(.year, from: Date())
      var memories: [Memory] = days.map { day in
        Memory(
          kind: .onThisDay(yearsAgo: currentYear - day.year), idList: ItemIDs(day.indices.compactMap(unfiltered.indexID(at:))),
          date: moments[day.indices[0]].date)
      }
      for trip in trips.prefix(12) {
        let located = trip.filter { moments[$0].latitude != nil }
        guard !located.isEmpty else { continue }
        let middle = located[located.count / 2]
        memories.append(
          Memory(
            kind: .trip(latitude: moments[middle].latitude ?? 0, longitude: moments[middle].longitude ?? 0),
            idList: ItemIDs(trip.reversed().compactMap(unfiltered.indexID(at:))), date: moments[trip[0]].date))
      }
      return memories
    }.value
  }
}

private struct MemoryCard: View {
  let library: UnifiedLibraryModel
  let memory: Memory
  @State private var place: String?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      LibraryThumbnail(
        id: memory.idList.values.first.flatMap(library.position(ofIndexID:)).map(library.itemID(at:)), bucket: .large,
        source: library.thumbnailSource)
      LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 2) {
        Text(place ?? memory.title).font(.headline)
        Text(subtitle).font(.caption)
      }
      .foregroundStyle(.white)
      .padding(12)
    }
    .frame(width: 200, height: 260)
    .clipShape(.rect(cornerRadius: 18))
    .contentShape(.rect(cornerRadius: 18))
    .accessibilityElement(children: .combine)
    .task {
      guard case .trip(let latitude, let longitude) = memory.kind else { return }
      place = await PlaceNameCache.shared.cityName(latitude: latitude, longitude: longitude)
    }
  }

  private var subtitle: String {
    switch memory.kind {
    case .onThisDay: memory.date.formatted(date: .abbreviated, time: .omitted)
    case .trip: place == nil ? String(localized: "Trip") : memory.title
    }
  }
}

// MARK: - People

enum FaceCropCache {
  private static let cache = SendableImageCache(countLimit: 128, totalCostLimit: 16 * 1024 * 1024)

  static func object(forKey key: NSString) -> CGImage? { cache.object(forKey: key) }
  static func setObject(_ image: CGImage, forKey key: NSString, identity: ThumbnailIdentity) {
    let store = { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
    if let mediaKey = RemoteThumbnailID(identity.id)?.mediaKey {
      LockedItems.whileUnlocked(mediaKey, accountEmail: identity.accountEmail, store)
    } else {
      store()
    }
  }
  static func removeAll() { cache.removeAllObjects() }
}

/// A face cut out of its photo.
struct PersonChip: View {
  let library: UnifiedLibraryModel
  let person: Person
  let side: CGFloat
  var showsCaption = true
  @Environment(\.displayScale) private var displayScale
  @State private var image: CGImage?
  @State private var loadedKey: String?
  @State private var loadedIdentity: ThumbnailIdentity?
  @State private var token: ImageRequestToken?

  var body: some View {
    VStack(spacing: 4) {
      Circle()
        .fill(.quaternary)
        .overlay {
          if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
              .frame(width: side, height: side).clipped()
          } else {
            Image(systemName: "person.fill").font(.system(size: side * 0.4)).foregroundStyle(.secondary)
          }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
      if showsCaption {
        Text(person.name ?? String(localized: "Unnamed"))
          .font(.caption.weight(.medium)).lineLimit(1)
        Text(person.faceCount, format: .number)
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(width: showsCaption ? side + 12 : side)
    .accessibilityElement(children: .combine)
    .onAppear(perform: load)
    .onReceive(NotificationCenter.default.publisher(for: LockedItems.didLock).receive(on: DispatchQueue.main)) { _ in
      if loadedIdentity?.isLocked == true {
        token?.cancel()
        token = nil
        image = nil
      }
    }
    // Search can open before the library has loaded, or the person's cover can update.
    .onChange(of: library.reloadToken) { load() }
    .onChange(of: person.cover?.id) { load() }
    .onDisappear {
      token?.cancel()
      token = nil
    }
  }

  private func load() {
    // The cover may be a photo that's only in Google Photos now; drop pixels if it left the library.
    let identity = person.cover.flatMap { library.position(ofIndexID: $0.itemID) }.map(library.thumbnailIdentity(at:))
    guard let face = person.cover, let identity, !identity.isLocked else {
      token?.cancel()
      token = nil
      loadedKey = nil
      loadedIdentity = nil
      image = nil
      return
    }
    loadedIdentity = identity
    let itemID = identity.id
    let targetFacePixels = side * displayScale * 1.6
    let faceFraction = max(min(face.rect.width, face.rect.height), 0.05)
    let requestSide = min(max(ceil(targetFacePixels / faceFraction), side * displayScale), 600)
    let account = library.cloud?.library.accountEmail ?? ""
    let key =
      "\(account)|\(itemID)|\(face.id)|\(Int((face.rect.minX * 1_000).rounded())),\(Int((face.rect.minY * 1_000).rounded())),\(Int((face.rect.width * 1_000).rounded())),\(Int((face.rect.height * 1_000).rounded()))|\(Int(requestSide))"
    if loadedKey == key, image != nil { return }
    if let cached = FaceCropCache.object(forKey: key as NSString) {
      token?.cancel()
      token = nil
      loadedKey = key
      image = cached
      return
    }
    token?.cancel()
    loadedKey = key
    token = library.thumbnailSource.requestImage(
      id: itemID, pixelSize: CGSize(width: requestSide, height: requestSide), quality: .uncroppedThumbnail
    ) { full, isFinal in
      // Face coordinates refer to the whole photo, so request aspect-fit before cropping.
      let width = CGFloat(full.width)
      let height = CGFloat(full.height)
      let faceRect = CGRect(
        x: face.rect.minX * width, y: face.rect.minY * height,
        width: face.rect.width * width, height: face.rect.height * height)
      let cropSide = min(max(faceRect.width, faceRect.height) * 1.6, min(width, height))
      let rect = CGRect(
        x: min(max(0, faceRect.midX - cropSide / 2), width - cropSide),
        y: min(max(0, faceRect.midY - cropSide / 2), height - cropSide), width: cropSide, height: cropSide)
      let result = full.cropping(to: rect.integral) ?? full
      if isFinal {
        FaceCropCache.setObject(result, forKey: key as NSString, identity: identity)
      }
      Task { @MainActor in
        if loadedKey == key, !identity.isLocked { image = result }
      }
    }
  }
}

struct PeopleView: View {
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  @State private var people: [Person] = []

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 20) {
        ForEach(people) { person in
          NavigationLink(value: SearchRoute.person(id: person.id, name: person.name)) {
            PersonChip(library: library, person: person, side: 88)
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
    .overlay {
      if people.isEmpty {
        ContentUnavailableView(
          "No People Yet", systemImage: "person.2",
          description: Text("People appear as your photos are analyzed on this device."))
      }
    }
    .navigationTitle("People")
    // Everyone seen in a few photos; the Search tab's row keeps to those seen most.
    .task(id: indexer.contentRevision) { people = (try? await indexer.store.people(minimumFaces: 3)) ?? [] }
  }
}

struct PersonView: View {
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  let personID: Int64
  @State private var name: String?
  @State private var ids: [String]?
  @State private var isNaming = false
  @State private var draft = ""
  @State private var isChoosingMerge = false
  /// Another person already called the name just given, offered for a merge.
  @State private var sameName: LibraryIndexStore.NamedPerson?
  @Environment(\.dismiss) private var dismiss

  init(library: UnifiedLibraryModel, indexer: LibraryIndexer, personID: Int64, name: String?) {
    self.library = library
    self.indexer = indexer
    self.personID = personID
    _name = State(initialValue: name)
  }

  var body: some View {
    ResultsGridView(title: name ?? String(localized: "Unnamed Person"), library: library, ids: ids)
      .toolbar {
        Menu {
          Button {
            draft = name ?? ""
            isNaming = true
          } label: {
            Label(name == nil ? "Add Name" : "Rename", systemImage: "pencil")
          }
          Button {
            isChoosingMerge = true
          } label: {
            Label("Merge With…", systemImage: "person.2")
          }
          Button(role: .destructive) {
            Task {
              try? await indexer.store.hide(person: personID)
              indexer.peopleDidChange()
              dismiss()
            }
          } label: {
            Label("Hide This Person", systemImage: "eye.slash")
          }
        } label: {
          Label("More", systemImage: "ellipsis")
        }
      }
      .alert(name == nil ? "Add Name" : "Rename", isPresented: $isNaming) {
        TextField("Name", text: $draft)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
          let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          name = value.isEmpty ? nil : value
          Task {
            try? await indexer.store.name(person: personID, name)
            indexer.peopleDidChange()
            // Photos asks the same: a second person with this name is usually a duplicate.
            guard let name else { return }
            let others = (try? await indexer.store.namedPeople()) ?? []
            sameName = others.first {
              $0.id != personID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
          }
        }
      } message: {
        Text("Their photos become searchable by this name.")
      }
      .alert(
        "Merge with the Other “\(sameName?.name ?? "")”?",
        isPresented: Binding(get: { sameName != nil }, set: { if !$0 { sameName = nil } }),
        presenting: sameName
      ) { other in
        Button("Merge") { merge(personID: other.id, otherName: other.name) }
        Button("Keep Separate", role: .cancel) {}
      } message: { _ in
        Text("If they’re the same person, their photos are combined here.")
      }
      .sheet(isPresented: $isChoosingMerge) {
        MergePersonPicker(library: library, indexer: indexer, excluding: personID) { other in
          isChoosingMerge = false
          merge(personID: other.id, otherName: other.name)
        }
      }
      .task(id: indexer.contentRevision) { ids = (try? await indexer.store.ids(ofPerson: personID)) ?? [] }
  }

  private func merge(personID otherID: Int64, otherName: String?) {
    Task {
      let merged = (try? await indexer.store.merge(person: otherID, into: personID)) ?? false
      if merged, name == nil { name = otherName }
      indexer.peopleDidChange()
    }
  }
}

/// The other people, to pick the one that's the same person as this one.
private struct MergePersonPicker: View {
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  let excluding: Int64
  let choose: (Person) -> Void
  @State private var people: [Person]?
  @State private var chosen: Person?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 20) {
          ForEach(people ?? []) { person in
            Button {
              chosen = person
            } label: {
              PersonChip(library: library, person: person, side: 88)
            }
            .buttonStyle(.plain)
          }
        }
        .padding()
      }
      .overlay {
        if people == nil {
          ProgressView()
        } else if people?.isEmpty == true {
          ContentUnavailableView("No Other People", systemImage: "person.2")
        }
      }
      .navigationTitle("Merge With")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .alert(
        "Merge These People?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
        presenting: chosen
      ) { person in
        Button("Merge") { choose(person) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Their photos are combined into one person.")
      }
      // People shown only once they have a few photos are often the duplicates, so
      // everyone with two or more is offered.
      .task {
        people = ((try? await indexer.store.people(minimumFaces: 2)) ?? []).filter { $0.id != excluding }
      }
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 420)
    #endif
  }
}

// MARK: - Cleanup tools

/// Groups of near-identical photos on this device, with the best shot suggested.
struct SimilarPhotosView: View {
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  @State private var groups: [[(id: String, score: Float?)]]?
  @State private var pendingDelete: [String] = []
  @State private var errorMessage: String?

  var body: some View {
    List {
      if let groups {
        if !groups.isEmpty {
          Section {
            Button("Keep the Best of Every Group") {
              pendingDelete = groups.flatMap { group in Self.extras(group) }
            }
          } footer: {
            Text("The best photo of each group is chosen by sharpness and composition, analyzed on this device.")
          }
        }
        ForEach(groups.indices, id: \.self) { index in
          let group = groups[index]
          Section {
            ScrollView(.horizontal) {
              HStack(spacing: 8) {
                ForEach(group, id: \.id) { member in
                  LibraryThumbnail(id: member.id, bucket: .medium, source: library.thumbnailSource)
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                      if member.id == Self.best(group) {
                        Image(systemName: "star.circle.fill").symbolRenderingMode(.multicolor).padding(4)
                          .accessibilityLabel(Text("Best"))
                      }
                    }
                }
              }
            }
            .scrollIndicators(.hidden)
            Button("Keep Best, Delete \(group.count - 1)", role: .destructive) { pendingDelete = Self.extras(group) }
          }
        }
      } else {
        ProgressView()
      }
    }
    .overlay {
      if let groups, groups.isEmpty {
        ContentUnavailableView(
          "No Similar Photos", systemImage: "square.on.square",
          description: Text("Bursts and near-identical shots appear here as your photos are analyzed."))
      }
    }
    .navigationTitle("Similar Photos")
    .confirmationDialog(
      "Delete \(pendingDelete.count) Photos?",
      isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        let ids = pendingDelete
        Task {
          var assets: [PHAsset] = []
          PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
          do {
            try await LibraryActions.delete(assets)
            await load()
          } catch let error as PHPhotosError where error.code == .userCancelled {
          } catch {
            errorMessage = error.localizedDescription
          }
        }
      }
    } message: {
      Text("They're also removed from iCloud Photos on your other devices, if you use it.")
    }
    .alert("Couldn't Delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK") {}
    } message: {
      Text(errorMessage ?? "")
    }
    // Grouping reads every print, so it reruns when indexing finishes, not during it.
    .task(id: indexer.isIndexing ? -1 : indexer.contentRevision) { await load() }
  }

  static func best(_ group: [(id: String, score: Float?)]) -> String? {
    group.max { ($0.score ?? -1) < ($1.score ?? -1) }?.id
  }

  static func extras(_ group: [(id: String, score: Float?)]) -> [String] {
    let keep = best(group)
    return group.map(\.id).filter { $0 != keep }
  }

  private func load() async {
    let existing = await library.deviceIDs()
    groups = (try? await indexer.store.similarGroups(existing: existing)) ?? []
  }
}

/// Items stored more than once in Google Photos (identical bytes), keeping the newest.
struct CloudDuplicatesView: View {
  let library: UnifiedLibraryModel
  let cloud: CloudLibrary
  @State private var groups: [[RemoteItemSummary]]?
  @State private var pendingTrash: [RemoteItemSummary] = []
  @State private var errorMessage: String?

  var body: some View {
    List {
      if let groups {
        if !groups.isEmpty {
          Section {
            Button("Keep One of Each") { pendingTrash = groups.flatMap { Array($0.dropFirst()) } }
          } footer: {
            Text("These items have identical contents. Extras move to Google Photos' Trash for 60 days.")
          }
        }
        ForEach(groups.indices, id: \.self) { index in
          let group = groups[index]
          Section {
            HStack(spacing: 8) {
              ForEach(group) { item in
                LibraryThumbnail(
                  id: RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion).string,
                  bucket: .medium, source: cloud.thumbnails
                )
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 8))
              }
              Spacer()
              Button("Keep One", role: .destructive) { pendingTrash = Array(group.dropFirst()) }
            }
          } footer: {
            Text(group.first?.fileName ?? "")
          }
        }
      } else {
        ProgressView()
      }
    }
    .overlay {
      if let groups, groups.isEmpty {
        ContentUnavailableView("No Duplicates", systemImage: "doc.on.doc", description: Text("Nothing is stored twice."))
      }
    }
    .navigationTitle("Duplicates")
    .confirmationDialog(
      "Move \(pendingTrash.count) Items to Trash?",
      isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } }),
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        let items = pendingTrash
        Task {
          do {
            try await cloud.trash(items)
            await load()
          } catch {
            errorMessage = error.localizedDescription
          }
        }
      }
    } message: {
      Text("You can restore them from Trash in Google Photos for 60 days.")
    }
    .alert("Couldn't Finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK") {}
    } message: {
      Text(errorMessage ?? "")
    }
    .task(id: cloud.revision) { await load() }
  }

  private func load() async {
    // Only the duplicated items, newest group first, without reading the whole library.
    groups = await cloud.duplicateGroups()
  }
}
