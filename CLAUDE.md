# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a macOS SwiftUI app. Open and build via Xcode:

```
open xviewerSwift/xviewerSwift.xcodeproj
```

There is no CLI build command — the project must be built and run through Xcode (⌘R). Minimum target: macOS 13.0 (Ventura), Xcode 15+.

There are no automated tests. The `test.swift`, `test_alert.swift`, and `test_modifier.swift` files in the root of `xviewerSwift/` are scratch/experimental files, not a test suite.

## Architecture

The app is a single-window SwiftUI application (`xviewerSwiftApp.swift`) with a forced dark color scheme.

### Core Data Flow

`BrowserSession` (`BrowserSession.swift`) is the central `@MainActor ObservableObject` that owns all state for a single browser pane: current folder URL, folder contents (`[FileItem]`), selection state, full-screen image URL, sort order, rename alerts, and navigation history. Nearly all user actions (navigate, delete, rename, sort, copy/move) are methods on `BrowserSession`.

`ContentView` (`ContentView.swift`) creates two `BrowserSession` instances (`session` and `sessionRight`) for dual-pane support and an `activePane: ActivePane` enum to route keyboard actions to the correct session. It wires `sidebarSelection` URL changes → `session.loadFolder()` and `session.fullScreenImageURL` changes → `ImmersiveWindowController` (borderless fullscreen window).

### Key Components

- **`PaneBrowserView`** — renders a `LazyVGrid` of `GridItemCell` views for one session; handles rubber-band drag selection via `RubberBandSelectionGesture` view modifier; propagates scroll via a `ScrollViewReader`.
- **`SidebarManager`** — `@MainActor ObservableObject` managing Sources/Bookmarks/Recents. Recents are frequency-sorted and capped at 7. All folder URLs are persisted as security-scoped bookmarks in `UserDefaults`.
- **`SidebarNavigationView`** — sidebar UI driven by `SidebarManager`; supports drag-and-drop onto sidebar items to move files.
- **`FullScreenImageView`** — presented in a borderless `ImmersiveWindow` (`.screenSaver` level) via `ImmersiveWindowController.shared`. Owns local state for zoom (`ZoomState`), rotation, invert, B&W, and horizontal flip filters.
- **`GridItemCell`** — individual cell view with context menu, drag source, drop target (folders only), and tap gestures.

### Thumbnail Loading Pipeline

Three-tier pipeline in `FileItemView.loadThumbnail()`:
1. **Memory cache** (`ThumbnailCache`, `NSCache`) — instant
2. **Disk cache** (`ThumbnailDiskCache`, JPEG at `~/Library/Caches/com.d13.xviewerSwift/Thumbnails/`) — keyed by SHA256 of `path_modDate_fileSize`
3. **Generation** — 150ms scroll-settle debounce, then `ThumbnailLoader` semaphore (8 concurrent local / 2 remote), CGImageSource for local files or `QLThumbnailGenerator` as fallback

### Keyboard Handling

Two parallel systems exist (a known area of complexity): SwiftUI `.keyboardShortcut` modifiers on invisible `Button` views in `shortcutsGroup`, and an `NSEvent.addLocalMonitorForEvents` in `setupKeyboardMonitor()`. The monitor handles keys that SwiftUI shortcuts can't reliably intercept (arrow keys, character-jump-to-item, F2). The monitor checks `firstResponder` class name for "Text" to avoid intercepting rename text fields.

### File Operations

All file operations use security-scoped URLs. The pattern is always: `startAccessingSecurityScopedResource()` → operation → `stopAccessingSecurityScopedResource()`. Collision handling appends `_1`, `_2`, etc. Bulk rename uses a two-phase approach (temp UUID names → final names) to avoid intra-batch collisions.

### Image Formats

Only `jpg`, `jpeg`, `png`, `gif`, `heic`, `webp` are shown as image items. Other file types are counted in `otherFileCount` but not displayed. Non-image files do not get thumbnail slots in the grid.

### External App Integration

- **Krita**: opens via bundle ID `org.kde.krita`, falls back to `/Applications/Krita.app`
- **Lightroom**: copies associated `.cr2` RAW to a `LightroomTemp/` staging folder inside the configured Favorites directory, then opens via bundle ID `com.adobe.LightroomClassicCC7`
