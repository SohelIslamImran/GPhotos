import AppIntents
import GPhotosKit

/// The Library's entities and intents (photos, people, albums, search) come from GPhotosKit.
struct LibraryIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [GPhotosKitIntents.self] }
}
