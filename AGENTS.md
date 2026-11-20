# AGENTS.md

Guidance for coding agents (and humans) working in this repository.

## What this is

GPhotos backs up photos and videos to Google Photos in original quality from
iPhone (Photos library, Files folders, share sheet) and Mac (watched folders, drops,
share extension). It is a personal-use app: there are no legacy users, so never add
migrations, compatibility shims, or deprecated paths. Change the code directly.

## Layout

| Path | Contents |
| --- | --- |
| `GPhotosKit/` | Shared framework (built twice: `GPhotosKit` for iOS, `GPhotosKitMac`). |
| `GPhotosKit/Network` | Google auth (`GoogleAuthService`, token binding in `TokenBinding`), mobile API client, sign-in sheet (`WebAuthSheet`), `NetworkStatusMonitor`. |
| `GPhotosKit/Protocol` | Hand-written protobuf encoding/decoding for the mobile API; `LibraryMessages` (library sync and actions, sync templates, a lazy `ProtoMessage` reader for sync pages). |
| `GPhotosKit/Upload` | `SyncEngine` (shared app model base), `UploadWorkerPool`, `Backoff`, `BatchUploadProgress` (pure byte-weighted batch progress and speed), `AccountMirror` (idle-time copies to secondary accounts), `BackgroundUploader` (the photo upload extension's uploads, tracked in `BackgroundUploadLedger` and sent by the background URLSession in `BackgroundUploadTransfers`). |
| `GPhotosKit/Storage` | `TransferManifestStore` (actor, the source of truth for every upload/deletion), `TransferRecord`, `LibraryCleanupPlanner`, keychain (account list + primary), album keys and 20,000-item rollover. |
| `GPhotosKit/Scanner` | Photos-library export, Live Photos (`LivePhotoMetadata` pairs folder files by Apple content identifier), album mirroring, `FolderMediaScanner` (folder scanning shared by iOS and macOS). |
| `GPhotosKit/Library` | The library browser: `PhotoGridRenderer` (one `CALayer` per visible cell, laid out by `PhotoGridLayout` arithmetic, shared by the iOS `UIScrollView` and macOS `NSScrollView` hosts in `PhotoGridView`), `ThumbnailPipeline` (coalesced, cancellable requests and a RAM-sized memory cache), `PhotoKitImageSource` (windowed `PHCachingImageManager`), `PhotoLibraryGridModel` (any `LibraryScope` + `LibraryFilter`, `TimelineIndex` month sections), `LibraryView` (Years/Months/All, Select mode, context menus), `LibraryActions` (favorite, hide, albums, delete after an in-app confirmation; `SharedAsset` exports lazily for share/drag), `Unified/` (the Library tab: `TimelineMerge` joins device, backed-up folder and Google Photos items into one timeline, matching by upload record, content hash, or capture time and size; `UnifiedLibraryModel`, `UnifiedLibraryView`; on iPhone `LibrarySnapshot` saves the grid's newest screen as the app leaves and draws it on the next launch's first frame until the live grid fades in over it), `Folders/` (`FolderLibrary` reads the backed-up folders for the Library, holding each folder's access while it's listed; `FolderThumbnailSource` reads images and video frames from the files; `FileViewerPage`; folder files are shared, never deleted, from the Library), `Viewer/` (`MediaViewer` for any mix of device and Google items, paged by `PagedViewer` (`UIPageViewController` / `NSPageController`, only the current page and its neighbours exist), native zoom in `ZoomableImage`, info panels, Live Photo playback), `Collections/` (pinned, albums, media types, utilities, Places map, Hidden behind device authentication), `Intelligence/` (on-device only: `ItemAnalyzer` runs Vision labels, text, feature prints, faces and aesthetics on small thumbnails; `LibraryIndexStore` keeps them in SQLite with FTS5; `LibraryIndexer` indexes at utility priority and pauses in Low Power Mode or when hot; Google items are indexed by metadata first, then analyzed from a small thumbnail each, fetched on Wi-Fi, or on cellular / a hotspot only with Use Cellular Data (Use Personal Hotspot) on, never in Low Data Mode (`GoogleThumbnailSource.analysisImage`), and not cached; Places maps the merged library, Google-only items included; `SearchView` with Memories, People, categories, Similar Photos and Google duplicates), `Siri/` (the new Siri, iOS/macOS 27: `PhotoEntity` (`.photos.asset`), `PersonEntity` (`.photos.recognizedPerson`) and `AlbumEntity` (`.photos.album`), shaped as Xcode's schema catalog (`AppIntentSchemas.sqlite` in the toolchain) requires; `SiriSpotlightIndexer` puts every Library item into the Spotlight semantic index after each `LibraryIndexer` pass, incrementally, from `siri_items` records in the index database, so entity queries work when Siri runs the app without its window; `SiriLibrary` is the shared store, headless search (`SiriSearchQuery` reads periods, videos and favorites from spoken words) and the navigation request the app's root views carry out; the viewer's `userActivity` and the grid's `appEntityUIElementProvider` tell Siri what's on screen; `GPhotosKitIntents` is registered by each app's `LibraryIntentsPackage`), `Remote/` (the Google Photos library: `RemoteLibraryStore` SQLite mirror per account, `RemoteLibrarySync` full/delta sync, `GoogleThumbnailSource` with a disk cache, `CloudLibrary`, `CloudLibraryView` for Google-only scopes in Collections, `RemoteViewerPage`, `KeptThumbnails` (a small thumbnail saved from the device copy just before cleanup removes it, so the item keeps showing from Google Photos; best effort, never blocks or changes a deletion) and `RecentlyViewed` (Keep Recently Viewed holds back photos opened in the viewer lately)). Plan: `docs/library-client-plan.md`. |
| `GPhotosKit/Notifications` | `BackupNotifier`: local notifications for both apps. |
| `GPhotosKit/UI` | Shared SwiftUI: `MediaThumbnail` (memory-only thumbnails), `BackupActivityAttributes` (Live Activity), `BackupStatus` (pure status logic) and `DisplayedBackupStatus`, `StatusCard`, `StatTile`, `SettingsGroup`/`SettingRow`, `ActivityRow`/`TransferStateBadge`/`ActivityFilterBar`, `AccountAvatar`/`AccountSummaryView`, `StateGallery` (DEBUG). |
| `GPhotosKit/AppGroup` | Settings store, shared queue between app and share extensions. |
| `GPhotosSync/` | iOS app (`AppModel`, `ContentView`, sheets, Activity, Folders, Protected Items, background tasks, Back Up Photos shortcut). |
| `GPhotosSyncMac/` | macOS app (`MacSyncStore`, sidebar window with Pinned, Albums and Google Photos collections and a sidebar search field, Activity as a sortable table, menu bar extra, folder watcher). |
| `ShareExtension/`, `MacShareExtension/` | Share extensions that hand files to the app through the App Group queue. |
| `PhotosUploadExtension/` | iOS 27 photo upload extension: iOS runs it on its own schedule, even after the app is closed; the app records its uploads. iOS refuses to enable it (`PHPhotosErrorDomain -1`) without `BackgroundUploadURLBase` in its Info.plist. |
| `BackupWidgets/` | iOS widget extension: the backup Live Activity and the widgets in `Widgets/`. |
| `MacWidgets/` | macOS widget extension with the widgets in `Widgets/`. |
| `Widgets/` | Memories (On This Day, trips, featured photos), People (an `AppIntentConfiguration` choosing a person) and Backup status widgets, compiled into both widget extensions. They read only what `GPhotosKit/Widgets` `WidgetPublisher` writes to the App Group's `Widgets/` folder (a JSON snapshot and a small JPEG per photo): the app picks the photos from the merged library and the index, and writes the backup status as it changes. Taps open `gphotosapp://photo?id=`, `person?id=` or `backup`. |
| `Resources/AppIcon.icon` | The app icon (Icon Composer, Liquid Glass layers), used by both apps. |
| `Resources/Shared.xcassets` | Assets used by both apps (the Google Photos logo); loaded from the main bundle. |
| `Tests/GPhotosKitTests` | Swift Testing unit tests (run on both platforms). |
| `Tests/GPhotosSyncUITests` | XCUITest suite for the iOS app. |
| `docs/` | Library implementation and roadmap. Use generated Debug cloud data for screenshots. |
| `scripts/build-and-run.sh` | Unsigned builds by default. Optional developer-provided signing settings. |

`GPhotosSync.xcodeproj` is generated. Edit `project.yml`, then run `xcodegen generate`.
New source files are only picked up after regenerating.

## Build and test

```bash
xcodegen generate
# macOS unit tests (no signing needed)
xcodebuild -project GPhotosSync.xcodeproj -scheme GPhotosSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
# iOS unit + UI tests on a simulator (UI tests need signing for the App Group)
xcodebuild -project GPhotosSync.xcodeproj -scheme GPhotosSync -destination 'platform=iOS Simulator,name=<any iPhone simulator>' DEVELOPMENT_TEAM=<team> test
```

Debug-only review hooks: launch with `-UIScreen <name>` (iOS: `backup` (Library is the first tab), `activity`, `failed`,
`account`, `signIn`, `upload`, `protected`, `folders`, `library`, `collections`, `viewer`, `cloud`, `cloudViewer`, `cloudCollections` (the Library and Collections with a generated Google library, no network), `cloudLarge` (100,000 generated items, for checking speed at scale), `cloudGridStress` / `cloudPinchStress` / `cloudFilmstripStress` (fling the 100,000-item grid, pinch it through every column count, or scrub the viewer's filmstrip from a display link and log `STRESS` frame times, hitches and per-frame work with `NSLog` to the unified log), `search` (with `-UISearchQuery <text>`), `gallery`, `widgets` (every widget at its sizes with the data last published; `-UIRefreshWidgets YES` publishes again at launch); macOS: `overview` (opens Backup, like `uploading`), `library`, `collections`, `search`, `viewer`, `cloud`, `cloudViewer`, `cloudCollections`,
`activity`, `failed`, `folders`, `settings`, `storage` (Settings), `signIn`, `signInGoogle`, `signInSwitch`, `menubar`,
`menubarUploading`, `gallery`, `widgets`; both: `uploading` (simulated uploads, no network), `share`, `shareLoading`, `sharePreparing`, `shareDone`, `shareError`
for the share extension UI) and on macOS `-UIAppearance dark|light` and `-UISnapshot <path.png>` (writes the main
window to a PNG after `-UISnapshotDelay` seconds, for review without screen recording access; translucent
sidebar and glass surfaces don't draw in it). These compile out of Release.

## Conventions

- Swift 6 strict concurrency. Models are `@MainActor @Observable`; PhotoKit, file
  enumeration, hashing and bookmark resolution run off the main actor
  (`Task.detached` / `nonisolated static`).
- Style: 2-space indent, `swift-format` with the repo's `.swift-format`. Comments only
  where they explain a non-obvious *why*.
- UI: native SwiftUI + Liquid Glass (`glassEffect`, `.glass`/`.glassProminent`). Use
  Apple system colors (Display P3) only; no custom RGB unless defined in Display P3.
  Color belongs in icon tiles and status, surfaces are neutral glass. Animations are
  critically damped springs/`.smooth`; respect Reduce Motion. Keep iOS and macOS in
  parity while following each platform's conventions (macOS: sidebar sections incl.
  Settings, menu bar extra, keyboard shortcuts, context menus).
- Copy: short, plain, actionable ("Choose a Delete After Backup time to use this."),
  never internal jargon.

## Safety rules (do not weaken)

- Nothing is ever deleted unless the manifest proves a verified upload to the *current*
  account (`eligibleForDeletion` → `claimForDeletion` → re-check → delete → `markDeleted`,
  with rollback on any failure). Files are moved to a tombstone and their content hash is
  verified before the record is marked deleted. Cleanup candidates are also confirmed with
  Google Photos first (`RemoteCopyVerifier`: a hash check for the still and, for a Live
  Photo, its motion); anything not found, or any error, holds the item back.
- A hash match proves the bytes are in the account, not their quality (it may be a Storage
  saver copy). Items found that way are recorded in `foundInAccounts` and are only removed
  when the user turns on Remove Items Found in Google Photos.
- iPhone Photos library deletions always go through one `PHAssetChangeRequest.deleteAssets`
  call after an in-app confirmation (iOS also shows its own prompt; it cannot be bypassed).
  Assets are skipped if edited after upload, favorites/protected albums, RAW or Live Photo
  parts not uploaded, incomplete bursts, shared items, or not deletable. With Back Up
  Originals of Edits on, an edited asset also waits for its unedited original (its own
  `.uneditedOriginal` record), since deleting the asset deletes the original too.
- Files in backed-up folders are removed silently after the delay, never inside protected
  folders, never in shared iCloud items, and only with balanced security-scoped access.
- With several accounts, an item is removed only after every account that keeps a copy
  has it. The primary account always uploads first; secondary copies run only at idle
  time (charging / plugged in and idle), one item at a time, and pause when the primary
  starts. Each account keeps its own androidId, auth service and cookie-less sessions.
- Keep mobile protocol field numbers, order, and omitted values stable. Upload commits
  use the fixed metered profile for regular files and both Live Photo paths. Preserve
  original quality. A Live Photo's motion hash check uses `sha1MediaType` PhodeoMovie
  (field 5 = 2). A plain lookup cannot find motion attached to its still.
- Avatars use a separate `userinfo.profile` token, which is never cached or used for
  photo requests. `AccountPhotoStore` caches the image and refreshes it monthly.
- Library sync bodies in `LibrarySyncTemplates.swift` preserve the captured wire bytes.
  Only token fields are substituted. `CloudLibraryTests` verifies the request fixtures.
- Remote actions touch only the browsed account, use dedup keys from the server, and ask
  first with a count. Delete moves items to Trash (restorable for 60 days); only items
  already in Trash can be deleted for good with Delete Forever.
  Full and delta syncs share the account's 429 back-off; deltas run at most every 10 minutes
  unless the user asks, or a backup to the account has just finished (one delta at least a
  minute after the last sync, shared by batches close together). The mirror and thumbnail
  cache are deleted with the account.
- Performance changes must not trade away functionality: uploads keep working on battery,
  in Low Data Mode and in the background.

## Before finishing a change

1. `xcodegen generate` if files were added/removed.
2. Build and test both platforms (commands above); keep warnings at zero.
3. `swift-format lint` the touched files, `git diff --check`, `bash -n scripts/*.sh`.
4. For UI changes, check light and dark with the `-UIScreen` hooks.
