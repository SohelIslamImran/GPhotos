# README screenshots

Captured from Debug builds on 2026-11-21. The Share Extension image uses the public GPhotos build. The Library, Collections,
Viewer, Places and Search screens use generated gradient media from `-UIScreen cloud` /
`cloudViewer` / `cloudCollections`, and Backup uses simulated uploads from
`-UIScreen uploading`, without personal photos or a live Google account.
These images document the UI, not live Google API validation.

| File | Screen | Capture |
| --- | --- | --- |
| `ios_library.png` | Library tab (light) | iPhone 18 Pro Max, iOS 27.2, `-UIScreen cloud` |
| `ios_library_dark.png` | Library tab (dark) | Same simulator, dark appearance |
| `ios_collections.png` | Collections tab | Same simulator, `-UIScreen cloudCollections` |
| `ios_viewer.png` | Full-screen Viewer & filmstrip | Same simulator, `-UIScreen cloudViewer` |
| `ios_viewer_info.png` | Viewer Media Info sheet | Same simulator, Info button in `cloudViewer` |
| `ios_places.png` | Places map | Same simulator, Explore Places from `cloud` |
| `ios_search.png` | Search results | Same simulator, `"Paris"` search in `cloud` |
| `ios_backup.png` | Backup tab (uploading) | Same simulator, `-UIScreen uploading` |
| `ios_share.png` | Share Extension sheet | Same simulator, `-UIScreen share` |
| `mac_library.png` | Library (light) | macOS Debug, light, 1000 × 680 pt window (`-UIScreen cloud`) |
| `mac_library_dark.png` | Library (dark) | Same window, dark (`-UIScreen cloud -UIAppearance dark`) |
| `mac_viewer.png` | Viewer & floating Info panel | Same window, `-UIScreen cloudViewer` with `⌘I` |
| `mac_collections.png` | Collections | Same window, `-UIScreen cloudCollections` |
| `mac_overview.png` | Backup (uploading) | Same window, `-UIScreen uploading` |
| `mac_folders.png` | Folders & skip rules | Same window, `-UIScreen folders` |
| `mac_settings.png` | Settings | Same window, `-UIScreen settings` |

## Reproduce

1. Generate the project with `xcodegen generate` and build Debug for each platform.
   See [AGENTS.md](../../AGENTS.md) for build destinations and signing.
2. Use a simulator or an isolated signed-out macOS environment (`HOME` in a temporary
   directory). Launch with `-UIScreen cloud` (or `cloudViewer`, `cloudCollections`,
   `uploading`, `share`, `folders`, `settings`) to seed in-memory generated cloud data or
   simulated uploads without touching the network.
3. On iPhone, normalize the simulator status bar (`9:41`, full signal/Wi-Fi, 100%
   charged) and capture at 1× logical resolution (`440 × 956`). Capture both light and
   dark appearances, plus interactive flows (tapping Info in the Viewer, searching
   `"Paris"`, and opening Places).
4. On Mac, launch with `-UIAppearance light` (or `dark`) and capture the full app window
   with `screencapture -l <windowID> -o` so the translucent Liquid Glass sidebar, search
   field and floating Info panel render faithfully (avoid `-UISnapshot` for README images,
   as it omits translucent sidebar and glass layers).
5. Inspect every PNG for permission dialogs, transient menus, private account details,
   personal folders/photos and mid-transition frames before committing.

The README embeds these files directly. Keep filenames stable when replacing them.
