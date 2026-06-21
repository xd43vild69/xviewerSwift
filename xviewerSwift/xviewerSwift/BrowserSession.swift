import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Thumbnail Loader (Per-Pane Semaphore)
class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var activeTasks = 0
    var maxTasks = 8
    private var pendingContinuations: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let lock = NSLock()

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if activeTasks < maxTasks {
                    activeTasks += 1
                    lock.unlock()
                    continuation.resume(returning: ())
                } else {
                    pendingContinuations.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let index = pendingContinuations.firstIndex(where: { $0.0 == id }) {
                let continuation = pendingContinuations.remove(at: index).1
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        activeTasks -= 1

        if !pendingContinuations.isEmpty && activeTasks < maxTasks {
            activeTasks += 1
            let continuation = pendingContinuations.removeFirst().1
            lock.unlock()
            continuation.resume(returning: ())
        } else {
            lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        for (_, continuation) in pendingContinuations {
            continuation.resume(throwing: CancellationError())
        }
        pendingContinuations.removeAll()
        activeTasks = 0
        lock.unlock()
    }
}

// MARK: - Undo/Redo Types
enum FileOperationType {
    case move(sources: [URL], destination: URL)
    case copy(destinations: [URL])
    case rename(source: URL, oldName: String)
    case createFolder(folderURL: URL)
    case delete(source: URL)
}

struct UndoableAction {
    let operation: FileOperationType
    let timestamp: Date

    var actionDescription: String {
        switch operation {
        case .move(let sources, _):
            let count = sources.count
            return count == 1 ? "Moved '\(sources[0].lastPathComponent)'" : "Moved \(count) items"
        case .copy(let destinations):
            let count = destinations.count
            return count == 1 ? "Copied '\(destinations[0].lastPathComponent)'" : "Copied \(count) items"
        case .rename(_, let oldName): return "Renamed '\(oldName)'"
        case .createFolder(let url): return "Created '\(url.lastPathComponent)'"
        case .delete(let source): return "Deleted '\(source.lastPathComponent)'"
        }
    }
}

@MainActor
class BrowserSession: ObservableObject {
    @Published var currentColumnCount: Int = 1
    @Published var currentFolderURL: URL?
    @Published var folderContents: [FileItem] = []
    @Published var fullScreenImageURL: URL?
    @Published var selectedItemURLs: Set<URL> = []
    @Published var activeItemURL: URL?
    @Published var currentSortOrder: SortOrder = .name
    @Published var metadataString: String = ""
    @Published var otherFileCount: Int = 0
    @Published var isScrolling: Bool = false

    /// Referencia compartida para registrar visitas recientes desde cualquier ruta de navegación
    /// (incluyendo Enter key y navegar a carpeta padre, que antes no registraban).
    weak var sidebarManager: SidebarManager?

    /// Range selection state: tracks anchor point for Shift+Arrow deselection (Finder-style)
    var selectionAnchorURL: URL?
    var selectionAnchorIndex: Int?
    /// Selection that existed when the anchor was set (e.g. Ctrl+Click disjunct sets).
    /// Each Shift+Arrow computes `base ∪ range` so contracting the range deselects correctly.
    var selectionBaseURLs: Set<URL> = []

    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    lazy var thumbnailLoader: ThumbnailLoader = ThumbnailLoader()

    @Published var isShowingProperties = false
    @Published var propertiesURL: URL?
    
    @Published var isShowingSingleRenameAlert = false
    @Published var singleRenameBaseName: String = ""
    @Published var itemToRename: URL?

    @Published var isShowingBulkRenameAlert = false
    @Published var bulkRenameBaseName: String = ""
    @Published var showCopiedFeedback: Bool = false
    @Published var notificationMessage: String? = nil
    @Published var folderHistory: [URL: URL] = [:]
    @Published var compareImageURLs: [URL]? = nil
    @Published private(set) var undoHistory: [UndoableAction] = []
    @Published private(set) var canUndo: Bool = false

    // Navigation history stack (back/forward)
    @Published var navigationHistory: [URL] = []
    @Published var navigationIndex: Int = -1

    var imageItems: [FileItem] {
        folderContents.filter { !$0.isDirectory }
    }

    var canGoBack: Bool {
        navigationIndex > 0
    }

    var canGoForward: Bool {
        navigationIndex >= 0 && navigationIndex < navigationHistory.count - 1
    }

func copySelectedItemToClipboard() {
        guard !self.selectedItemURLs.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(self.selectedItemURLs.map { $0 as NSURL })
    }
    
    func pasteFromClipboard(move: Bool = false) {
        guard let targetFolder = self.currentFolderURL else { return }
        let pasteboard = NSPasteboard.general
        
        var pastedSomething = false
        
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return }
            
            if move {
                let destAccessed = targetFolder.startAccessingSecurityScopedResource()
                defer { if destAccessed { targetFolder.stopAccessingSecurityScopedResource() } }

                let fm = FileManager.default
                var successfullyMoved: [URL] = []
                var movedSet: Set<URL> = []

                for sourceURL in fileURLs {
                    if sourceURL.deletingLastPathComponent().standardizedFileURL == targetFolder.standardizedFileURL {
                        continue
                    }

                    let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()
                    let originalName = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension
                    var finalURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)

                    var counter = 1
                    while fm.fileExists(atPath: finalURL.path) {
                        let newName = ext.isEmpty ? "\(originalName)_\(counter)" : "\(originalName)_\(counter).\(ext)"
                        finalURL = targetFolder.appendingPathComponent(newName)
                        counter += 1
                    }

                    do {
                        try fm.moveItem(at: sourceURL, to: finalURL)
                        successfullyMoved.append(sourceURL)
                        movedSet.insert(sourceURL)
                        pastedSomething = true
                    } catch {
                        print("Error moving file \(sourceURL.lastPathComponent): \(error)")
                    }

                    if sourceAccessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                if pastedSomething {
                    let nextFocus = self.computeNextFocus(for: self.activeItemURL ?? self.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: movedSet)
                    self.loadFolder(url: targetFolder, sidebarManager: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let next = nextFocus {
                            self.activeItemURL = next
                            self.selectedItemURLs = [next]
                        }
                    }
                    showNotification("Moved \(successfullyMoved.count) items")
                } else {
                    NSSound.beep()
                }
            } else {
                var copiedDestinations: [URL] = []
                for sourceURL in fileURLs {
                    let destinationURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)
                    do {
                        if !FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                            pastedSomething = true
                            copiedDestinations.append(destinationURL)
                        }
                    } catch {
                        print("Error copying file: \(error)")
                    }
                }

                // Register ONE action for ALL copied files
                if !copiedDestinations.isEmpty {
                    recordOperation(.copy(destinations: copiedDestinations))
                }

                if pastedSomething {
                    loadFolder(url: targetFolder, sidebarManager: nil)
                } else {
                    NSSound.beep()
                }
            }
        } else if !move, let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
            if let tiff = firstImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let pngData = bitmap.representation(using: .png, properties: [:]) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let fileName = "Pasted Image \(formatter.string(from: Date())).png"
                let destinationURL = targetFolder.appendingPathComponent(fileName)
                do {
                    try pngData.write(to: destinationURL)
                    pastedSomething = true
                } catch {
                    print("Error saving image: \(error)")
                }
            }
            
            if pastedSomething {
                loadFolder(url: targetFolder, sidebarManager: nil)
            } else {
                NSSound.beep()
            }
        }
    }
    
    func selectAllItems() {
        self.selectedItemURLs = Set(self.folderContents.filter { !$0.isDirectory }.map { $0.url })
    }

    func selectAllItemsAndFolders() {
        self.selectedItemURLs = Set(self.folderContents.map { $0.url })
    }

    func jumpToFirstItem(startingWith character: String) {
        guard !folderContents.isEmpty else { return }
        let prefix = character.lowercased()
        
        let currentIndex = folderContents.firstIndex { $0.url == activeItemURL } ?? -1
        var searchStartIndex = 0
        
        if currentIndex >= 0 {
            let currentItemName = folderContents[currentIndex].name.lowercased()
            if currentItemName.hasPrefix(prefix) {
                searchStartIndex = currentIndex + 1
            }
        }
        
        for i in searchStartIndex..<folderContents.count {
            if folderContents[i].name.lowercased().hasPrefix(prefix) {
                let match = folderContents[i]
                self.activeItemURL = match.url
                self.selectedItemURLs = [match.url]
                return
            }
        }
        
        if searchStartIndex > 0 {
            for i in 0...currentIndex {
                if folderContents[i].name.lowercased().hasPrefix(prefix) {
                    let match = folderContents[i]
                    self.activeItemURL = match.url
                    self.selectedItemURLs = [match.url]
                    return
                }
            }
        }
    }
    
    private func computeNextFocus(for itemURL: URL, excluding targets: Set<URL>) -> URL? {
        let allItems = self.folderContents.filter { !$0.isDirectory }

        guard let index = allItems.firstIndex(where: { $0.url == itemURL }) else {
            return allItems.first(where: { !targets.contains($0.url) })?.url
        }

        // Try to find the previous item that is not being excluded
        for i in stride(from: index - 1, through: 0, by: -1) {
            if !targets.contains(allItems[i].url) {
                return allItems[i].url
            }
        }

        // If no previous item found, try to find the next item
        for i in stride(from: index + 1, to: allItems.count, by: 1) {
            if !targets.contains(allItems[i].url) {
                return allItems[i].url
            }
        }

        return nil
    }

    func deleteSelectedItem() {
        var targets = self.selectedItemURLs
        if let fsURL = self.fullScreenImageURL { targets.insert(fsURL) }
        guard !targets.isEmpty else { return }

        let nextURL = computeNextFocus(for: self.fullScreenImageURL ?? self.activeItemURL ?? self.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: targets)

        for url in targets {
            do {
                // Try trash first (reversible)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                recordOperation(.delete(source: url))
            } catch {
                // Fallback to permanent delete (NOT recorded, not reversible)
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    print("Error deleting file \(url.lastPathComponent): \(error)")
                }
            }
        }

        self.folderContents.removeAll(where: { targets.contains($0.url) })
        self.selectedItemURLs = []
        if let next = nextURL {
            self.selectedItemURLs = [next]
            self.activeItemURL = next
        } else {
            self.activeItemURL = nil
        }
        if self.fullScreenImageURL != nil { self.fullScreenImageURL = nextURL }
    }
    
    func moveItem(_ url: URL) {
        var targets = self.selectedItemURLs
        if !targets.contains(url) { targets.insert(url) }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose destination folder"

        if panel.runModal() == .OK, let destinationURL = panel.url {
            let nextURL = computeNextFocus(for: self.activeItemURL ?? self.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: targets)

            do {
                for tURL in targets {
                    let finalURL = destinationURL.appendingPathComponent(tURL.lastPathComponent)
                    try FileManager.default.moveItem(at: tURL, to: finalURL)
                }
                self.folderContents.removeAll(where: { targets.contains($0.url) })
                self.selectedItemURLs = []
                if let next = nextURL {
                    self.selectedItemURLs = [next]
                    self.activeItemURL = next
                } else {
                    self.activeItemURL = nil
                }
                if self.fullScreenImageURL != nil { self.fullScreenImageURL = nextURL }
            } catch {
                print("Error moving file: \(error)")
                NSSound.beep()
            }
        }
    }
    
    
    func showNotification(_ message: String) {
        notificationMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.notificationMessage == message {
                self.notificationMessage = nil
            }
        }
    }

    func moveFiles(urls: [URL], to destinationDir: URL) {
        let destAccessed = destinationDir.startAccessingSecurityScopedResource()
        defer { if destAccessed { destinationDir.stopAccessingSecurityScopedResource() } }

        var successfullyMoved: Set<URL> = []
        let fm = FileManager.default

        for sourceURL in urls {
            let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()

            let originalName = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            var finalURL = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)

            var counter = 1
            while fm.fileExists(atPath: finalURL.path) {
                let newName = ext.isEmpty ? "\(originalName)_\(counter)" : "\(originalName)_\(counter).\(ext)"
                finalURL = destinationDir.appendingPathComponent(newName)
                counter += 1
            }

            do {
                try fm.moveItem(at: sourceURL, to: finalURL)
                successfullyMoved.insert(sourceURL)
            } catch {
                print("Error moving file \(sourceURL.lastPathComponent): \(error)")
            }

            if sourceAccessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if !successfullyMoved.isEmpty {
            // Register UNO acción para TODOS los archivos movidos
            recordOperation(.move(sources: Array(successfullyMoved), destination: destinationDir))

            DispatchQueue.main.async {
                let nextFocus = self.computeNextFocus(for: self.activeItemURL ?? self.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: successfullyMoved)
                self.folderContents.removeAll(where: { successfullyMoved.contains($0.url) })
                self.selectedItemURLs.subtract(successfullyMoved)
                if let next = nextFocus {
                    self.activeItemURL = next
                    self.selectedItemURLs = [next]
                } else {
                    self.activeItemURL = nil
                }
            }
        }
    }
    
    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "lastFolderBookmark")
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    func restoreBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "lastFolderBookmark") else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            guard (try? url.checkResourceIsReachable()) == true else {
                UserDefaults.standard.removeObject(forKey: "lastFolderBookmark")
                return nil
            }
            
            if isStale {
                saveBookmark(for: url)
            }
            return url
        } catch {
            print("Failed to restore secure last folder bookmark: \(error)")
            UserDefaults.standard.removeObject(forKey: "lastFolderBookmark")
            return nil
        }
    }
    
    func updateMetadata(for url: URL?) {
        metadataTask?.cancel()

        guard let url = url else {
            self.metadataString = ""
            return
        }

        let name = url.lastPathComponent
        self.metadataString = "\(name)  |  Loading..."

        metadataTask = Task.detached(priority: .userInitiated) {
            let isAccessed = url.startAccessingSecurityScopedResource()
            defer { if isAccessed { url.stopAccessingSecurityScopedResource() } }
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await MainActor.run {
                    guard self.activeItemURL == url || (self.activeItemURL == nil && self.currentFolderURL == url) else { return }
                    self.metadataString = "Folder: \(name)"
                }
                return
            }
            
            var sizeStr = "Unknown Size"
            if let attr = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attr[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useKB, .useBytes]
                formatter.countStyle = .file
                sizeStr = formatter.string(fromByteCount: size)
            }
            
            var dimensionsStr = ""
            if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                if width > 0 && height > 0 {
                    dimensionsStr = " - \(width) x \(height)"
                }
            }
            
            let finalMetadata = "\(name)  |  \(sizeStr)\(dimensionsStr)"
            
            await MainActor.run {
                guard self.activeItemURL == url || (self.activeItemURL == nil && self.currentFolderURL == url) else { return }
                self.metadataString = finalMetadata
            }
        }
    }
    
    func createNewFolderWithSelection() {
        guard let currentDir = self.currentFolderURL, !self.selectedItemURLs.isEmpty else { return }
        
        let fm = FileManager.default
        var newFolderName = "new folder"
        var finalURL = currentDir.appendingPathComponent(newFolderName)
        var counter = 1
        
        while fm.fileExists(atPath: finalURL.path) {
            newFolderName = "new folder \(counter)"
            finalURL = currentDir.appendingPathComponent(newFolderName)
            counter += 1
        }
        
        do {
            try fm.createDirectory(at: finalURL, withIntermediateDirectories: true, attributes: nil)
            
            let itemsToMove = Array(self.selectedItemURLs)
            for itemURL in itemsToMove {
                let destURL = finalURL.appendingPathComponent(itemURL.lastPathComponent)
                try fm.moveItem(at: itemURL, to: destURL)
            }
            
            loadFolder(url: currentDir, sidebarManager: nil)
            
            DispatchQueue.main.async {
                self.selectedItemURLs = [finalURL]
                self.activeItemURL = finalURL
                self.promptSingleRename(for: finalURL)
            }
            
        } catch {
            print("Error creating folder with selection: \(error)")
            NSSound.beep()
        }
    }

    func createNewFolder() {
        guard let currentDir = self.currentFolderURL else { return }
        
        let alert = NSAlert()
        alert.messageText = "Create New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = "New Folder"
        alert.accessoryView = textField
        
        alert.layout()
        alert.window.initialFirstResponder = textField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }
            
            let newURL = currentDir.appendingPathComponent(folderName)
            do {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true, attributes: nil)
                recordOperation(.createFolder(folderURL: newURL))
                // Pre-register the new folder in history so loadFolder() restores focus to it
                self.folderHistory[currentDir] = newURL
                loadFolder(url: currentDir, sidebarManager: nil) // Refresh the view
            } catch {
                print("Error creating folder: \(error)")
                NSSound.beep()
            }
        }
    }
    
    func openWithKrita(_ url: URL) {
        var targets = self.selectedItemURLs
        if !targets.contains(url) {
            targets.insert(url)
        }
        
        for target in targets {
            _ = target.startAccessingSecurityScopedResource()
        }
        
        let kritaURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.kde.krita") 
                       ?? URL(fileURLWithPath: "/Applications/Krita.app")
                       
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(Array(targets), withApplicationAt: kritaURL, configuration: config) { _, error in
            for target in targets {
                target.stopAccessingSecurityScopedResource()
            }
            if let error = error {
                print("Error opening with Krita: \(error)")
            }
        }
    }
    
    func openWithLightroom(_ url: URL) {
        guard let favoritesURL = AppSettings.shared.favoritesURL else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Favorites Folder Not Set"
                alert.informativeText = "Please configure a Favorites folder in Settings to use Open with Lightroom."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        let cr2URL = url.deletingPathExtension().appendingPathExtension("cr2")
        var isStale = false
        // Need to check if cr2 exists in the actual filesystem
        let fileManager = FileManager.default
        var cr2Exists = false
        
        let isAccessed = url.startAccessingSecurityScopedResource()
        defer { if isAccessed { url.stopAccessingSecurityScopedResource() } }
        
        if fileManager.fileExists(atPath: cr2URL.path) {
            cr2Exists = true
        }
        
        guard cr2Exists else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "RAW File Not Found"
                alert.informativeText = "Could not find a corresponding .cr2 file for \(url.lastPathComponent)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        let isFavoritesAccessed = favoritesURL.startAccessingSecurityScopedResource()
        defer { if isFavoritesAccessed { favoritesURL.stopAccessingSecurityScopedResource() } }
        
        let tempDirURL = favoritesURL.appendingPathComponent("LightroomTemp")
        do {
            if !fileManager.fileExists(atPath: tempDirURL.path) {
                try fileManager.createDirectory(at: tempDirURL, withIntermediateDirectories: true, attributes: nil)
            } else {
                let contents = try fileManager.contentsOfDirectory(at: tempDirURL, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try fileManager.removeItem(at: fileURL)
                }
            }
            
            let uniqueString = UUID().uuidString.prefix(6)
            let uniqueName = "\(cr2URL.deletingPathExtension().lastPathComponent)_\(uniqueString).cr2"
            let destURL = tempDirURL.appendingPathComponent(uniqueName)
            try fileManager.copyItem(at: cr2URL, to: destURL)
            
            let now = Date()
            try fileManager.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: destURL.path)
            
            let lightroomURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.LightroomClassicCC7") 
                           ?? URL(fileURLWithPath: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app")
            
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([destURL], withApplicationAt: lightroomURL, configuration: config) { _, error in
                if let error = error {
                    print("Error opening with Lightroom: \(error)")
                }
            }
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Error"
                alert.informativeText = "An error occurred while preparing the file for Lightroom: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    func renameSelected() {
        if selectedItemURLs.count > 1 {
            promptBulkRename()
        } else if let active = activeItemURL {
            promptSingleRename(for: active)
        }
    }
    
    func promptSingleRename(for url: URL) {
        let baseName = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "Enter a new name (extension will be preserved):"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = baseName
        alert.accessoryView = textField
        
        alert.layout()
        alert.window.initialFirstResponder = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty && newName != baseName {
                executeSingleRename(originalURL: url, newBaseName: newName)
            }
        }
    }

    func promptBulkRename() {
        let alert = NSAlert()
        alert.messageText = self.selectedItemURLs.count > 1 ? "Batch Rename \(self.selectedItemURLs.count) Files" : "Batch Rename All Files"
        alert.informativeText = "Enter base name for files:"
        alert.addButton(withTitle: self.selectedItemURLs.count > 1 ? "Rename" : "Rename All")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = textField
        
        alert.layout()
        alert.window.initialFirstResponder = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                executeBulkRename(baseName: newName)
            }
        }
    }

    func executeSingleRename(originalURL: URL, newBaseName: String) {
        let directory = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension
        let newURL = ext.isEmpty ? directory.appendingPathComponent(newBaseName) : directory.appendingPathComponent("\(newBaseName).\(ext)")

        Task { await processRenames(moves: [(originalURL, newURL)], focusURL: originalURL) }
    }

    func executeBulkRename(baseName: String) {
        guard let dir = self.currentFolderURL else { return }

        let filesToRename: [FileItem]
        if self.selectedItemURLs.count > 1 {
            filesToRename = self.folderContents.filter { self.selectedItemURLs.contains($0.url) && !$0.isDirectory }
        } else {
            filesToRename = self.folderContents.filter { !$0.isDirectory }
        }

        var moves: [(URL, URL)] = []
        for (index, file) in filesToRename.enumerated() {
            let originalURL = file.url
            let ext = originalURL.pathExtension
            let sequenceStr = String(format: "%05d", index + 1)
            let newFileName = ext.isEmpty ? "\(baseName)_\(sequenceStr)" : "\(baseName)_\(sequenceStr).\(ext)"
            let newURL = dir.appendingPathComponent(newFileName)
            moves.append((originalURL, newURL))
        }

        let logStr = moves.map { "\($0.0.lastPathComponent) -> \($0.1.lastPathComponent)" }.joined(separator: "\n")
        try? logStr.write(toFile: "/tmp/rename_log.txt", atomically: true, encoding: .utf8)
        Task { await processRenames(moves: moves, focusURL: self.activeItemURL) }
    }

    @MainActor
    func processRenames(moves: [(URL, URL)], focusURL: URL? = nil) async {
        // Register undo ONLY for single-item rename
        if moves.count == 1 {
            let (sourceURL, _) = moves[0]
            let oldName = sourceURL.lastPathComponent
            recordOperation(.rename(source: sourceURL, oldName: oldName))
        }

        let parentFolder = self.currentFolderURL
        let parentAccessed = parentFolder?.startAccessingSecurityScopedResource() ?? false
        let renamingURLs = Set(moves.map { $0.0 })

        // Phase 1: Rename to temporary names to avoid intra-batch collisions
        var tempMoves: [(URL, URL)] = []
        for (source, destination) in moves {
            if source == destination { continue }

            let itemAccessed = source.startAccessingSecurityScopedResource()
            let tempName = UUID().uuidString + "_" + source.lastPathComponent
            let tempURL = source.deletingLastPathComponent().appendingPathComponent(tempName)

            do {
                try FileManager.default.moveItem(at: source, to: tempURL)
                tempMoves.append((tempURL, destination))
            } catch {
                print("Error creating temp file for \(source.lastPathComponent): \(error)")
            }

            if itemAccessed {
                source.stopAccessingSecurityScopedResource()
            }
        }

        // Phase 2: Rename to final names
        for (tempURL, destination) in tempMoves {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    print("File already exists at destination: \(destination.path)")
                    continue
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                print("Error renaming temp file to \(destination.lastPathComponent): \(error)")
            }
        }

        if parentAccessed {
            parentFolder?.stopAccessingSecurityScopedResource()
        }

        if let url = self.currentFolderURL {
            let nextFocus = focusURL.flatMap { computeNextFocus(for: $0, excluding: renamingURLs) }
            self.loadFolder(url: url, sidebarManager: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let next = nextFocus {
                    self.activeItemURL = next
                    self.selectedItemURLs = [next]
                }
            }
        }
    }
    
    func handleUpArrow(shift: Bool = false) {
        if self.fullScreenImageURL == nil {
            navigateGridRow(direction: -1, shift: shift)
        }
    }
    
    func handleDownArrow(shift: Bool = false) {
        if self.fullScreenImageURL == nil {
            navigateGridRow(direction: 1, shift: shift)
        }
    }
    
    func navigateToFirst() {
        if self.fullScreenImageURL != nil {
            if let first = imageItems.first {
                self.fullScreenImageURL = first.url
                self.activeItemURL = first.url
                self.selectedItemURLs = [first.url]
            }
        } else {
            guard !self.folderContents.isEmpty else { return }
            if let first = self.folderContents.first {
                self.activeItemURL = first.url
                self.selectedItemURLs = [first.url]
            }
        }
    }
    
    func navigateToLast() {
        if self.fullScreenImageURL != nil {
            if let last = imageItems.last {
                self.fullScreenImageURL = last.url
                self.activeItemURL = last.url
                self.selectedItemURLs = [last.url]
            }
        } else {
            guard !self.folderContents.isEmpty else { return }
            if let last = self.folderContents.last {
                self.activeItemURL = last.url
                self.selectedItemURLs = [last.url]
            }
        }
    }
    
    func handleLeftArrow(shift: Bool = false) {
        if self.fullScreenImageURL != nil {
            navigateFullScreen(direction: -1)
        } else {
            navigateGrid(direction: -1, shift: shift)
        }
    }
    
    func handleRightArrow(shift: Bool = false) {
        if self.fullScreenImageURL != nil {
            navigateFullScreen(direction: 1)
        } else {
            navigateGrid(direction: 1, shift: shift)
        }
    }
    
    func navigateGridRow(direction: Int, shift: Bool) {
        guard !self.folderContents.isEmpty else { return }
        guard let currentSelected = self.activeItemURL, let currentIndex = self.folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            if let url = self.folderContents.first?.url {
                self.activeItemURL = url
                self.selectedItemURLs = [url]
                updateSelectionAnchor(url)
            }
            return
        }
        let newIndex = currentIndex + (direction * currentColumnCount)
        var targetURL: URL? = nil
        if newIndex >= 0 && newIndex < self.folderContents.count {
            targetURL = self.folderContents[newIndex].url
        } else if newIndex < 0 {
            targetURL = self.folderContents.first?.url
        } else if newIndex >= self.folderContents.count {
            targetURL = self.folderContents.last?.url
        }

        if let newURL = targetURL {
            self.activeItemURL = newURL
            if shift {
                // Range selection with anchor (Finder-style)
                if selectionAnchorURL == nil {
                    updateSelectionAnchor(currentSelected)
                }
                if let anchorIdx = selectionAnchorIndex,
                   let newIdx = self.folderContents.firstIndex(where: { $0.url == newURL }) {
                    let rangeItems = computeSelectionRange(from: anchorIdx, to: newIdx)
                    // base ∪ range: contracting the range deselects items outside it,
                    // while preserving Ctrl+Click selections captured in the base.
                    selectedItemURLs = selectionBaseURLs.union(rangeItems)
                }
            } else {
                // No shift: single selection + reset anchor
                self.selectedItemURLs = [newURL]
                updateSelectionAnchor(newURL)
            }
        }
    }
    
    func navigateGrid(direction: Int, shift: Bool) {
        guard !self.folderContents.isEmpty else { return }
        guard let currentSelected = self.activeItemURL, let currentIndex = self.folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            if let url = self.folderContents.first?.url {
                self.activeItemURL = url
                self.selectedItemURLs = [url]
                updateSelectionAnchor(url)
            }
            return
        }
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < self.folderContents.count {
            let newURL = self.folderContents[newIndex].url
            self.activeItemURL = newURL
            if shift {
                // Range selection with anchor (Finder-style)
                if selectionAnchorURL == nil {
                    updateSelectionAnchor(currentSelected)
                }
                if let anchorIdx = selectionAnchorIndex,
                   let newIdx = self.folderContents.firstIndex(where: { $0.url == newURL }) {
                    let rangeItems = computeSelectionRange(from: anchorIdx, to: newIdx)
                    // base ∪ range: contracting the range deselects items outside it,
                    // while preserving Ctrl+Click selections captured in the base.
                    selectedItemURLs = selectionBaseURLs.union(rangeItems)
                }
            } else {
                // No shift: single selection + reset anchor
                self.selectedItemURLs = [newURL]
                updateSelectionAnchor(newURL)
            }
        }
    }
    
    func navigateFullScreen(direction: Int) {
        guard let currentURL = self.fullScreenImageURL else { return }
        let images = imageItems
        guard let currentIndex = images.firstIndex(where: { $0.url == currentURL }) else { return }
        
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < images.count {
            let newURL = images[newIndex].url
            self.fullScreenImageURL = newURL
            self.activeItemURL = newURL
            self.selectedItemURLs = [newURL]
        }
    }
    
    func handleEnter() {
        guard self.fullScreenImageURL == nil else { return }
        guard let selected = self.activeItemURL else { return }
        
        if let item = self.folderContents.first(where: { $0.url == selected }) {
            if item.isDirectory {
                loadFolder(url: item.url, sidebarManager: nil)
            } else {
                self.fullScreenImageURL = item.url
            }
        }
    }
    
    func navigateUp() {
        guard let current = self.currentFolderURL else { return }
        let parentURL = current.deletingLastPathComponent()

        if current.path == parentURL.path { return }

        if FileManager.default.isReadableFile(atPath: parentURL.path) {
            loadFolder(url: parentURL, sidebarManager: nil)
        } else {
            let panel = NSOpenPanel()
            panel.message = "Please grant access to the parent folder to navigate up."
            panel.prompt = "Grant Access"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = parentURL

            if panel.runModal() == .OK, let selectedURL = panel.url {
                self.loadFolder(url: selectedURL, sidebarManager: nil)
            }
        }
    }

    func goBack() {
        guard navigationIndex > 0 else { return }
        navigationIndex -= 1
        let previousURL = navigationHistory[navigationIndex]
        loadFolder(url: previousURL, sidebarManager: nil, pushToHistory: false)
    }

    func goForward() {
        guard navigationIndex >= 0 && navigationIndex < navigationHistory.count - 1 else { return }
        navigationIndex += 1
        let nextURL = navigationHistory[navigationIndex]
        loadFolder(url: nextURL, sidebarManager: nil, pushToHistory: false)
    }

    private func withTimeout<T>(_ seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            while let result = try await group.next() {
                if let value = result {
                    group.cancelAll()
                    return value
                }
            }
            throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Folder load timed out"])
        }
    }

    func sortItems(_ items: [FileItem]) -> [FileItem] {
        return items.sorted {
            if $0.isDirectory && !$1.isDirectory { return true }
            if !$0.isDirectory && $1.isDirectory { return false }
            
            switch self.currentSortOrder {
            case .name:
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .date:
                return $0.creationDate > $1.creationDate
            case .size:
                return $0.fileSize > $1.fileSize
            }
        }
    }
    
    func loadFolder(url: URL, sidebarManager: SidebarManager?, pushToHistory: Bool = true) {
        loadTask?.cancel()

        // Quick SMB connectivity check - fallback to home if unavailable
        if isSMBPath(url) {
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let isConnected = await self.checkSMBConnectivity(url)

                if Task.isCancelled { return }

                if !isConnected {
                    await MainActor.run {
                        self.showNotification("⚠️ Network folder unavailable - loading home")
                    }
                    // Recursively load home instead
                    let homeURL = FileManager.default.homeDirectoryForCurrentUser
                    await MainActor.run {
                        self.loadFolder(url: homeURL, sidebarManager: sidebarManager, pushToHistory: pushToHistory)
                    }
                    return
                }

                // If connected, proceed with normal loading
                await MainActor.run {
                    self.performLoadFolder(url: url, sidebarManager: sidebarManager, pushToHistory: pushToHistory)
                }
            }
            return
        }

        performLoadFolder(url: url, sidebarManager: sidebarManager, pushToHistory: pushToHistory)
    }

    private func performLoadFolder(url: URL, sidebarManager: SidebarManager?, pushToHistory: Bool) {
        // Registrar la visita usando el manager pasado o la referencia guardada,
        // para que TODA navegación (doble-clic, Enter, subir a padre) cuente.
        (sidebarManager ?? self.sidebarManager)?.recordRecentVisit(url: url)
        if let current = self.currentFolderURL, let active = self.activeItemURL {
            folderHistory[current] = active
        }

        // Update navigation history for back/forward.
        // Skipped when called from goBack/goForward since they manage the index themselves.
        if pushToHistory {
            navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
            navigationHistory.append(url)
            navigationIndex = navigationHistory.count - 1
        }

        self.currentFolderURL = url
        self.folderContents = []
        self.otherFileCount = 0

        if let savedActive = folderHistory[url] {
            self.activeItemURL = savedActive
            self.selectedItemURLs = [savedActive]
        } else {
            self.activeItemURL = nil
            self.selectedItemURLs = []
        }

        var isLocalFolder = true
        if let resourceValues = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let local = resourceValues.volumeIsLocal {
            isLocalFolder = local
        }
        thumbnailLoader.maxTasks = isLocalFolder ? 24 : 2

        loadTask = Task.detached(priority: .userInitiated) { [weak self, isLocalFolder] in
            guard let self else { return }

            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .fileSizeKey, .volumeIsLocalKey]
            let timeoutSeconds = isLocalFolder ? 5.0 : 30.0

            let fileURLs: [URL]?
            do {
                fileURLs = try await self.withTimeout(timeoutSeconds) {
                    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.currentFolderURL == url else { return }
                    self.folderContents = []
                    self.showNotification("⏱️ Folder load timed out")
                }
                return
            }

            guard let fileURLs = fileURLs else {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.currentFolderURL == url else { return }
                    self.folderContents = []
                }
                return
            }

            if Task.isCancelled { return }

            var batch: [FileItem] = []
            var allItems: [FileItem] = []
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp"]
            var otherCountLocal = 0

            for fileURL in fileURLs {
                if Task.isCancelled { return }

                var isDirectory = false
                var fileDate = Date.distantPast
                var fileSize: Int64 = 0
                var isLocal = true

                if let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) {
                    isDirectory = resourceValues.isDirectory ?? false
                    fileDate = resourceValues.creationDate ?? Date.distantPast
                    fileSize = Int64(resourceValues.fileSize ?? 0)
                    isLocal = resourceValues.volumeIsLocal ?? true
                }

                let fileName = fileURL.lastPathComponent

                if !isDirectory {
                    let ext = fileURL.pathExtension.lowercased()
                    if imageExtensions.contains(ext) {
                        batch.append(FileItem(url: fileURL, name: fileName, isDirectory: false, creationDate: fileDate, fileSize: fileSize, isLocal: isLocal))
                    } else {
                        otherCountLocal += 1
                    }
                } else {
                    batch.append(FileItem(url: fileURL, name: fileName, isDirectory: true, creationDate: fileDate, fileSize: fileSize, isLocal: isLocal))
                }

                if batch.count >= 100 {
                    allItems.append(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)

                    if Task.isCancelled { return }

                    let snapshot = allItems
                    let countSnapshot = otherCountLocal
                    await MainActor.run {
                        guard self.currentFolderURL == url else { return }
                        self.folderContents = snapshot
                        self.otherFileCount = countSnapshot
                        if self.activeItemURL == nil {
                            if let u = snapshot.first?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
                        }
                    }
                }
            }

            if Task.isCancelled { return }

            allItems.append(contentsOf: batch)
            if !allItems.isEmpty {
                let sortedItems = await MainActor.run { self.sortItems(allItems) }

                if Task.isCancelled { return }

                await MainActor.run {
                    guard self.currentFolderURL == url else { return }
                    self.folderContents = sortedItems
                    self.otherFileCount = otherCountLocal
                    if self.activeItemURL == nil {
                        if let u = sortedItems.first?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
                    }
                }
            } else {
                await MainActor.run {
                    guard self.currentFolderURL == url else { return }
                    self.folderContents = []
                    self.otherFileCount = otherCountLocal
                }
            }
        }
    }

    func clearMemory() {
        self.folderHistory.removeAll()
        if let current = self.currentFolderURL {
            self.loadFolder(url: current, sidebarManager: nil)
        }
    }

    // MARK: - SMB Connectivity Check

    private func isSMBPath(_ url: URL) -> Bool {
        let pathString = url.path.lowercased()
        return pathString.hasPrefix("/volumes/") && (pathString.contains("smb") || pathString.contains("cifs"))
    }

    private func checkSMBConnectivity(_ url: URL) async -> Bool {
        guard isSMBPath(url) else { return true }

        let timeoutSeconds: TimeInterval = 2.0
        do {
            _ = try await withTimeout(timeoutSeconds) {
                try FileManager.default.attributesOfFileSystem(forPath: url.path)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Folder Partitioning (SMB Friendly)

    func partitionCurrentFolder() {
        guard let folderURL = currentFolderURL else { return }
        let folderName = folderURL.lastPathComponent

        let images = imageItems
        guard !images.isEmpty else { return }

        let blockSize = 100
        let blocks = stride(from: 0, to: images.count, by: blockSize)
            .map { Array(images[$0..<min($0 + blockSize, images.count)]) }

        for block in blocks {
            let partNum = nextAvailablePartitionNumber(in: folderURL, baseName: folderName)
            let partFolderName = "\(folderName)_\(partNum)"
            let partFolderURL = folderURL.appendingPathComponent(partFolderName)

            try? FileManager.default.createDirectory(at: partFolderURL,
                                                     withIntermediateDirectories: false)

            let imageURLs = block.map { $0.url }
            moveFiles(urls: imageURLs, to: partFolderURL)
        }

        loadFolder(url: folderURL, sidebarManager: sidebarManager)
    }

    private func nextAvailablePartitionNumber(in folderURL: URL, baseName: String) -> Int {
        let fm = FileManager.default
        var num = 1

        while fm.fileExists(atPath: folderURL.appendingPathComponent("\(baseName)_\(num)").path) {
            num += 1
        }
        return num
    }

    // MARK: - Undo/Redo Operations

    private func recordOperation(_ operation: FileOperationType) {
        undoHistory.append(UndoableAction(operation: operation, timestamp: Date()))
        canUndo = !undoHistory.isEmpty
    }

    func undoLastAction() {
        guard !undoHistory.isEmpty else {
            showNotification("⚠️ No undo operation available")
            return
        }

        let action = undoHistory.removeLast()
        canUndo = !undoHistory.isEmpty

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            switch action.operation {
            case .move(let sources, let destination):
                do {
                    // Determine origin folder (parent directory of sources)
                    let originFolder = sources.first?.deletingLastPathComponent()

                    // Move ALL files back to their original locations
                    for source in sources {
                        let movedFileURL = destination.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.moveItem(at: movedFileURL, to: source)
                    }
                    DispatchQueue.main.async {
                        self?.showNotification("✅ Undo: \(action.actionDescription)")
                        // Reload BOTH origin and destination folders to reflect the move
                        if let originFolder = originFolder {
                            self?.loadFolder(url: originFolder, sidebarManager: nil)
                        }
                        if let currentFolder = self?.currentFolderURL, currentFolder != originFolder {
                            self?.loadFolder(url: currentFolder, sidebarManager: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showNotification("❌ Could not undo move")
                    }
                }

            case .copy(let destinations):
                do {
                    // Delete ALL copied files
                    for destination in destinations {
                        try FileManager.default.removeItem(at: destination)
                    }
                    DispatchQueue.main.async {
                        self?.showNotification("✅ Undo: \(action.actionDescription)")
                        if let currentFolder = self?.currentFolderURL {
                            self?.loadFolder(url: currentFolder, sidebarManager: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showNotification("❌ Could not undo copy")
                    }
                }

            case .rename(let source, let oldName):
                do {
                    let parent = source.deletingLastPathComponent()
                    let oldURL = parent.appendingPathComponent(oldName)
                    try FileManager.default.moveItem(at: source, to: oldURL)
                    DispatchQueue.main.async {
                        self?.showNotification("✅ Undo: Restored '\(oldName)'")
                        if let currentFolder = self?.currentFolderURL {
                            self?.loadFolder(url: currentFolder, sidebarManager: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showNotification("❌ Could not undo rename")
                    }
                }

            case .createFolder(let folderURL):
                do {
                    try FileManager.default.removeItem(at: folderURL)
                    DispatchQueue.main.async {
                        self?.showNotification("✅ Undo: Deleted folder")
                        if let currentFolder = self?.currentFolderURL {
                            self?.loadFolder(url: currentFolder, sidebarManager: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showNotification("❌ Folder not empty, cannot undo")
                    }
                }

            case .delete:
                DispatchQueue.main.async {
                    self?.showNotification("⚠️ Item deleted to Trash. Restore manually from Trash.")
                }
            }
        }
    }

    // MARK: - Range Selection (Shift+Arrow with deselection)

    func updateSelectionAnchor(_ url: URL) {
        self.selectionAnchorURL = url
        self.selectionAnchorIndex = self.folderContents.firstIndex(where: { $0.url == url })
        // Capture the current selection as the base for upcoming Shift+Arrow extensions.
        self.selectionBaseURLs = self.selectedItemURLs
    }

    func computeSelectionRange(from anchorIndex: Int, to newIndex: Int) -> Set<URL> {
        let start = min(anchorIndex, newIndex)
        let end = max(anchorIndex, newIndex)
        return Set(folderContents[start...end].map { $0.url })
    }

}
