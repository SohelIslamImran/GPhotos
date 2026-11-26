# Library implementation and roadmap

Updated 2026-11-12 against the current source. This document replaces the original
2026-10-24 proposal. Items below describe implemented code, not a claim that every
private Google endpoint has been verified with a live account.

## Implemented

| Area | Current behavior | Main code |
| --- | --- | --- |
| Unified Library | Device Photos, backed-up folders and Google items in one timeline; matches by upload record, hash, or capture time and size; folder items remain visible without Photos access | `Library/Unified/TimelineMerge.swift`, `UnifiedLibraryModel.swift` |
| Grid | Shared layer renderer, arithmetic layout, visible cells only, cancellable/coalesced thumbnails, Years/Months/All, filters and selection; iPhone edge scrolling continues while the selecting finger rests | `PhotoGridRenderer`, `PhotoGridLayout`, `ThumbnailPipeline`, `LibraryView` |
| Launch | Last-screen restoration and an iPhone Library snapshot displayed until the live grid appears | `Library/Unified/LibrarySnapshot.swift`, app entry points |
| Viewer | Paged device, file and cloud media; current page and neighbors only; zoom, filmstrip, Live Photos, video, info, sharing and export | `Library/Viewer`, `Library/Folders/FileViewerPage.swift`, `Library/Remote/RemoteViewerPage.swift` |
| Collections | Pins, device albums, media types, utilities, Places map, authenticated device Hidden scope; Google Favorites, Archive, Trash, Uses Storage and an authenticated, read-only Locked Folder | `Library/Collections`, `Library/Remote/CloudLibraryView.swift` |
| Cloud mirror | SQLite per account, resumable full sync and delta sync, page/token commits, cycle and stuck-token guards | `RemoteLibraryStore`, `RemoteLibrarySync` |
| Cloud actions | Favorite, archive, caption, add/create album, Trash/restore, original download, share and video streaming | `Network/MobileLibraryClient.swift`, `Library/Remote` |
| Search | SQLite FTS5 metadata and OCR; Vision labels, feature prints, faces and aesthetics for device photos; word expansion | `Library/Intelligence` |
| Discovery | On This Day, trips, named/hidden face groups, categories, similar photos with a suggested best shot, Google duplicates | `Library/Intelligence/Grouping.swift`, `SearchView.swift` |
| Storage | Retained device thumbnails before cleanup; Keep Recently Viewed delays removal | `Library/Remote/KeptThumbnails.swift`, `RecentlyViewed.swift` |
| Folder media | Balanced security-scoped access, file thumbnails and video frames; Library exports never delete folder files | `Library/Folders` |

Paths in the table are relative to `GPhotosKit/` unless noted. Both apps open to the
Library. iPhone has Library, Collections, Search and Backup tabs. Mac has Library,
Collections and Search plus Backup, Activity, Folders and Settings in its sidebar.
The Mac grid and viewer follow the iPhone layout with native Mac navigation and input.

## Reference protocols

- The app uses the mobile protocol for Google sign-in, uploads, hash checks, and
  library sync. The tests compare library request bodies against captured fixtures.

## Sync, caches and privacy

Full and delta syncs share the account's 429 backoff. Routine deltas run at most every
10 minutes. An explicit refresh can run sooner; completed backups schedule a delta at
least a minute after the previous sync, coalescing nearby batches.

Cloud thumbnails are cached on disk per account; the grid requests media as needed.
Removing an account removes its mirror and thumbnail cache, without removing anything
from Google Photos. The local analysis index uses small device thumbnails at utility
priority and pauses in Low Power Mode or when the device is hot. Google items are
found by their metadata at once, then analyzed the same way from one small thumbnail
each, fetched on Wi-Fi (on cellular or a hotspot only with Use Cellular Data on, never in
Low Data Mode) and not kept.

## Backup and deletion rules

The manifest remains the source of truth for uploads and deletion. A cleanup candidate
must have a verified upload to the current account and all accounts keeping a copy.
`RemoteCopyVerifier` confirms the still and any Live Photo motion with Google before
cleanup. An error or missing copy holds the item back. A hash match proves presence,
not original quality; found copies require Remove Items Found in Google Photos.

The deletion claim is rechecked before removal. Folder files move to a tombstone and
their hash is verified before the manifest records deletion, with rollback on failure.
Protected folders and shared iCloud files are excluded. Device Photos deletion uses a
single PhotoKit request after in-app confirmation, followed by the system prompt.
Edited assets, incomplete RAW/Live Photo/burst uploads and protected assets stay put.
When backing up originals of edits, cleanup also waits for the unedited original.

Retained thumbnails are best effort and never authorize or block deletion. Recently
viewed protection is an additional delay. Remote Trash is separately confirmed with a
count and uses server dedup keys; it never bypasses local cleanup checks.

Primary uploads run first. Secondary account copies run one at a time at idle time
and pause for primary work. Uploads still work on battery, in Low Data Mode and in the
background. On iOS 27 the photo upload extension uses a background URLSession and
ledger, on the system's schedule. It requires `BackgroundUploadURLBase` in Info.plist.
Network recovery resumes pending work, while Stop cancels pending automatic resumes.
Mac launch respects Auto-Sync off.

## Remaining work and limits

- Live-account validation of library album membership and action round trips remains
  separate from fixture tests and generated `-UIScreen` review data.
- MobileCLIP natural-language image search needs a bundled model and is not built.
- Siri and Spotlight (iOS/macOS 27): Library items, named people and albums are App
  Intents entities on Siri's photos schemas, indexed into the Spotlight semantic index
  after each indexing pass; Siri can search, open, share and add to albums, and sees the
  photo on screen. Siri answers questions about photos from that index; the app doesn't
  run a language model of its own.
- Foundation Models query parsing, saved smart albums, local keyword editing,
  library widgets, memory movies, collages and Ask the Library remain roadmap ideas,
  not current capabilities. Slideshows are out of scope.
- Shared links, partner sharing, Google's face groups/search and total account quota
  are outside the current mobile-client implementation. The Locked Folder is read-only:
  the app has no request that moves items in or out of it.
  Charged bytes from sync do not represent the account's full storage quota.
- There is no web API integration, permanent deletion, or settings-based library
  kill switch. The original proposal's action journal and these features were plans.

## Verification

Use the build and test commands in [AGENTS.md](../AGENTS.md) on both platforms.
Fixture tests establish request encoding, not live API availability or storage policy.
The Debug `-UIScreen` hooks support generated cloud libraries without sign-in,
including 100,000-item grid, pinch and filmstrip stress cases on iPhone.
See [screenshot capture notes](screenshots/README.md) for the README images.
