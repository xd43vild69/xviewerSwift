# xviewerSwift

**xviewerSwift** is a modern, lightweight, and fast image viewer and file manager built natively for macOS using SwiftUI. Designed for efficiency and seamless navigation, xviewerSwift provides a rich set of features that combine the power of a dedicated file manager with an intuitive image browsing experience.

## Features

### 🖼 Core Image Viewing
- **Responsive Grid View:** Browse thumbnails and folders in a fast, dynamic grid layout that adapts to your window size.
- **Full-Screen Viewer:** Double-click or press Space/Enter to launch a distraction-free, full-screen image viewer.
- **Quick Filters:** Apply basic, non-destructive filters on the fly. Use `Cmd + B` for Black & White (Grayscale) and `Cmd + I` for Color Inversion.

### 📁 Advanced File Management
- **Favorites & RAW Workflow:**
  - **Quick Favorites (`Cmd + M`):** While in Full-Screen view, instantly copy the current image to a designated Favorites folder.
  - **Smart RAW Pairing:** When saving a favorite, the app automatically detects and copies any associated RAW file (e.g., `.cr2`, `.nef`, `.arw`) to keep your pairs intact.
  - **Global Settings:** Easily configure the destination path for your favorites via a sleek, native settings modal accessible from the sidebar.
- **Bulk & Single Renaming:** Easily rename single files or batch-rename multiple images sequentially with custom prefixes via the context menu.
- **Native Drag & Drop:** Seamlessly drag and drop files to move them into other folders within the grid or directly into pinned sidebar locations. 
- **Intelligent Collision Handling:** File movements and favorites copying handle naming conflicts automatically (appending suffixes like `_1` to images and their paired RAWs) without disrupting your workflow.
- **Create & Move:** Create new folders and move items using standard system dialogs.
- **Clipboard Support:** Copy (`Cmd + C`) and Paste (`Cmd + V`) selected items smoothly across directories.

### 🧭 Navigation & Organization
- **Smart Sidebar:**
  - **Sources:** Quick access to standard directories like Home, Downloads, and Pictures.
  - **Bookmarks:** Pin your favorite or frequently accessed folders for immediate access.
  - **Recents:** Automatically tracks and dynamically sorts recently visited folders based on frequency of use.
- **Flexible Sorting:** Sort folder contents by Name, Date, or Size.
- **Deep Keyboard Integration:** Navigate grids and menus instantly using Arrow keys, and use system-standard shortcuts (`Cmd+Backspace` to delete, `Esc` to close).

### 🔍 Detailed File Properties
- **Properties Panel:** View detailed metadata about selected files, including file dimensions, accurate file size, and creation/modification timestamps.

### 🎨 External Integration
- **Open with Krita:** Dedicated integration to send images directly to the Krita digital painting application for advanced editing.

## Requirements
- macOS 13.0+ (Ventura) or later.
- Xcode 15.0+ (for building and development).

## Architecture
Built entirely with Swift and SwiftUI, focusing on concurrency (`async`/`await`) for non-blocking file I/O and thumbnail generation. Security-scoped URL handling ensures safe access to system directories chosen by the user.

---
*Developed with a focus on speed, utility, and native macOS aesthetics.*
