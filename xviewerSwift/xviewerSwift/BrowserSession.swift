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

// MARK: - File Operation State
@MainActor
class FileOperationState: ObservableObject {
    @Published var isActive = false
    @Published var currentFile = ""
    @Published var progress: Double = 0
    @Published var totalCount = 0
    @Published var processedCount = 0
    @Published var errorMessage: String?

    var cancellationToken = UUID()

    func reset() {
        isActive = false
        currentFile = ""
        progress = 0
        totalCount = 0
        processedCount = 0
        errorMessage = nil
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
    private var preloadTask: Task<Void, Never>?

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

    @Published var fileOperation = FileOperationState()

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

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return }

            let operationID = UUID()
            fileOperation.cancellationToken = operationID

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }

                DispatchQueue.main.async { [weak self] in
                    self?.fileOperation.isActive = true
                    self?.fileOperation.totalCount = fileURLs.count
                    self?.fileOperation.processedCount = 0
                }

                let destAccessed = targetFolder.startAccessingSecurityScopedResource()
                defer { if destAccessed { targetFolder.stopAccessingSecurityScopedResource() } }

                let fm = FileManager.default
                var successfullyProcessed: [URL] = []
                var processedSet: Set<URL> = []

                do {
                    for sourceURL in fileURLs {
                        if self.fileOperation.cancellationToken != operationID { break }

                        if sourceURL.deletingLastPathComponent().standardizedFileURL == targetFolder.standardizedFileURL {
                            DispatchQueue.main.async { [weak self] in
                                self?.fileOperation.processedCount += 1
                                self?.fileOperation.progress = Double(self?.fileOperation.processedCount ?? 0) / Double(fileURLs.count)
                            }
                            continue
                        }

                        let fileName = sourceURL.lastPathComponent
                        let ext = sourceURL.pathExtension.lowercased()
                        let isJpeg = ext == "jpg" || ext == "jpeg"

                        if isJpeg {
                            do {
                                if move {
                                    _ = try self.moveOrCopyImagePair(jpegURL: sourceURL, to: targetFolder, isCopy: false)
                                    successfullyProcessed.append(sourceURL)
                                    processedSet.insert(sourceURL)
                                    if let cr2 = self.findCompanionCR2(for: sourceURL) {
                                        processedSet.insert(cr2)
                                    }
                                } else {
                                    _ = try self.moveOrCopyImagePair(jpegURL: sourceURL, to: targetFolder, isCopy: true)
                                    successfullyProcessed.append(sourceURL)
                                }
                            } catch {
                                print("Error \(move ? "moving" : "copying") JPEG pair \(fileName): \(error)")
                            }
                        } else {
                            let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()
                            let originalName = sourceURL.deletingPathExtension().lastPathComponent
                            var finalURL = targetFolder.appendingPathComponent(fileName)

                            var counter = 1
                            while fm.fileExists(atPath: finalURL.path) {
                                let newName = ext.isEmpty ? "\(originalName)_\(counter)" : "\(originalName)_\(counter).\(ext)"
                                finalURL = targetFolder.appendingPathComponent(newName)
                                counter += 1
                            }

                            do {
                                if move {
                                    try fm.moveItem(at: sourceURL, to: finalURL)
                                    processedSet.insert(sourceURL)
                                } else {
                                    try fm.copyItem(at: sourceURL, to: finalURL)
                                }
                                successfullyProcessed.append(sourceURL)
                            } catch {
                                print("Error \(move ? "moving" : "copying") file \(fileName): \(error)")
                            }

                            if sourceAccessed {
                                sourceURL.stopAccessingSecurityScopedResource()
                            }
                        }

                        DispatchQueue.main.async { [weak self] in
                            self?.fileOperation.processedCount += 1
                            self?.fileOperation.progress = Double(self?.fileOperation.processedCount ?? 0) / Double(fileURLs.count)
                            self?.fileOperation.currentFile = fileName
                        }
                    }

                    if !successfullyProcessed.isEmpty {
                        if !move {
                            let destinations = successfullyProcessed
                            DispatchQueue.main.async { [weak self] in
                                self?.recordOperation(.copy(destinations: destinations))
                            }
                        }

                        DispatchQueue.main.async { [weak self] in
                            if move {
                                let nextFocus = self?.computeNextFocus(for: self?.activeItemURL ?? self?.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: processedSet)
                                self?.loadFolder(url: targetFolder, sidebarManager: nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if let next = nextFocus {
                                        self?.activeItemURL = next
                                        self?.selectedItemURLs = [next]
                                    }
                                }
                                self?.showNotification("Moved \(successfullyProcessed.count) items")
                            } else {
                                self?.loadFolder(url: targetFolder, sidebarManager: nil)
                            }
                            self?.fileOperation.reset()
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            NSSound.beep()
                            self?.fileOperation.reset()
                        }
                    }
                }
            }
        } else if !move, let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
            guard let targetFolder = self.currentFolderURL else { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }

                if let tiff = firstImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let pngData = bitmap.representation(using: .png, properties: [:]) {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                    let fileName = "Pasted Image \(formatter.string(from: Date())).png"
                    let destinationURL = targetFolder.appendingPathComponent(fileName)
                    do {
                        try pngData.write(to: destinationURL)
                        DispatchQueue.main.async { [weak self] in
                            self?.loadFolder(url: targetFolder, sidebarManager: nil)
                        }
                    } catch {
                        print("Error saving image: \(error)")
                        DispatchQueue.main.async {
                            NSSound.beep()
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        NSSound.beep()
                    }
                }
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

        let operationID = UUID()
        fileOperation.cancellationToken = operationID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async { [weak self] in
                self?.fileOperation.isActive = true
                self?.fileOperation.totalCount = targets.count
                self?.fileOperation.processedCount = 0
            }

            var successCount = 0
            var deletedURLs: [URL] = []

            do {
                for url in targets {
                    if self.fileOperation.cancellationToken != operationID { break }

                    let fileName = url.lastPathComponent

                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        DispatchQueue.main.async { [weak self] in
                            self?.recordOperation(.delete(source: url))
                        }
                        deletedURLs.append(url)
                        successCount += 1
                    } catch {
                        do {
                            try FileManager.default.removeItem(at: url)
                            deletedURLs.append(url)
                            successCount += 1
                        } catch {
                            print("Error deleting file \(fileName): \(error)")
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.fileOperation.processedCount = successCount
                        self?.fileOperation.progress = Double(successCount) / Double(targets.count)
                        self?.fileOperation.currentFile = fileName
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    self?.folderContents.removeAll(where: { deletedURLs.contains($0.url) })
                    self?.selectedItemURLs = []
                    if let next = nextURL {
                        self?.selectedItemURLs = [next]
                        self?.activeItemURL = next
                    } else {
                        self?.activeItemURL = nil
                    }
                    if self?.fullScreenImageURL != nil { self?.fullScreenImageURL = nextURL }
                    self?.fileOperation.reset()
                }
            }
        }
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

            let operationID = UUID()
            fileOperation.cancellationToken = operationID

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }

                DispatchQueue.main.async { [weak self] in
                    self?.fileOperation.isActive = true
                    self?.fileOperation.totalCount = targets.count
                    self?.fileOperation.processedCount = 0
                }

                var movedURLs: Set<URL> = []

                do {
                    var processedCount = 0
                    for tURL in targets {
                        if self.fileOperation.cancellationToken != operationID { break }

                        let fileName = tURL.lastPathComponent
                        let ext = tURL.pathExtension.lowercased()
                        let isJpeg = ext == "jpg" || ext == "jpeg"

                        if isJpeg {
                            _ = try self.moveOrCopyImagePair(jpegURL: tURL, to: destinationURL, isCopy: false)
                            movedURLs.insert(tURL)
                            if let cr2 = self.findCompanionCR2(for: tURL) {
                                movedURLs.insert(cr2)
                            }
                        } else {
                            let originalName = tURL.deletingPathExtension().lastPathComponent
                            var finalURL = destinationURL.appendingPathComponent(fileName)

                            var counter = 1
                            while FileManager.default.fileExists(atPath: finalURL.path) {
                                let newName = ext.isEmpty ? "\(originalName)_\(counter)" : "\(originalName)_\(counter).\(ext)"
                                finalURL = destinationURL.appendingPathComponent(newName)
                                counter += 1
                            }

                            try FileManager.default.moveItem(at: tURL, to: finalURL)
                            movedURLs.insert(tURL)
                        }

                        processedCount += 1
                        DispatchQueue.main.async { [weak self] in
                            self?.fileOperation.processedCount = processedCount
                            self?.fileOperation.progress = Double(processedCount) / Double(targets.count)
                            self?.fileOperation.currentFile = fileName
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.folderContents.removeAll(where: { movedURLs.contains($0.url) })
                        self?.selectedItemURLs = []
                        if let next = nextURL {
                            self?.selectedItemURLs = [next]
                            self?.activeItemURL = next
                        } else {
                            self?.activeItemURL = nil
                        }
                        if self?.fullScreenImageURL != nil { self?.fullScreenImageURL = nextURL }
                        self?.fileOperation.reset()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        print("Error moving file: \(error)")
                        NSSound.beep()
                        self?.fileOperation.reset()
                    }
                }
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

    private func findCompanionCR2(for jpegURL: URL) -> URL? {
        let baseName = jpegURL.deletingPathExtension().lastPathComponent
        let directory = jpegURL.deletingLastPathComponent()
        let cr2URL = directory.appendingPathComponent("\(baseName).cr2")

        if FileManager.default.fileExists(atPath: cr2URL.path) {
            return cr2URL
        }
        return nil
    }

    private func nextAvailableName(baseName: String, extension ext: String, in folder: URL) -> String {
        let finalName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        let finalURL = folder.appendingPathComponent(finalName)

        if !FileManager.default.fileExists(atPath: finalURL.path) {
            return baseName
        }

        var counter = 1
        while true {
            let newName = "\(baseName)_\(counter)"
            let newFullName = ext.isEmpty ? newName : "\(newName).\(ext)"
            let newURL = folder.appendingPathComponent(newFullName)
            if !FileManager.default.fileExists(atPath: newURL.path) {
                return newName
            }
            counter += 1
        }
    }

    private func moveOrCopyImagePair(
        jpegURL: URL,
        to destinationDir: URL,
        isCopy: Bool = false
    ) throws -> (URL, URL?) {
        let fm = FileManager.default

        let jpegSourceAccessed = jpegURL.startAccessingSecurityScopedResource()
        defer { if jpegSourceAccessed { jpegURL.stopAccessingSecurityScopedResource() } }

        let baseName = jpegURL.deletingPathExtension().lastPathComponent
        let jpegExt = jpegURL.pathExtension

        let companion = findCompanionCR2(for: jpegURL)
        let companionAccessed = companion.map { $0.startAccessingSecurityScopedResource() } ?? false
        defer { if companionAccessed { companion?.stopAccessingSecurityScopedResource() } }

        let nextName = nextAvailableName(baseName: baseName, extension: jpegExt, in: destinationDir)

        let finalJpegURL = destinationDir.appendingPathComponent(
            jpegExt.isEmpty ? nextName : "\(nextName).\(jpegExt)"
        )
        let finalCR2URL = companion.map { _ in
            destinationDir.appendingPathComponent("\(nextName).cr2")
        }

        if fm.fileExists(atPath: finalJpegURL.path) {
            throw NSError(domain: "BrowserSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "JPEG file already exists at destination"])
        }

        if let finalCR2 = finalCR2URL, fm.fileExists(atPath: finalCR2.path) {
            throw NSError(domain: "BrowserSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CR2 file already exists at destination"])
        }

        do {
            if isCopy {
                try fm.copyItem(at: jpegURL, to: finalJpegURL)
                if let companion = companion, let finalCR2 = finalCR2URL {
                    try fm.copyItem(at: companion, to: finalCR2)
                }
            } else {
                try fm.moveItem(at: jpegURL, to: finalJpegURL)
                if let companion = companion, let finalCR2 = finalCR2URL {
                    try fm.moveItem(at: companion, to: finalCR2)
                }
            }
        } catch {
            if !isCopy && fm.fileExists(atPath: finalJpegURL.path) {
                try? fm.removeItem(at: finalJpegURL)
            }
            throw error
        }

        return (finalJpegURL, finalCR2URL)
    }

    func moveFiles(urls: [URL], to destinationDir: URL) {
        let operationID = UUID()
        fileOperation.cancellationToken = operationID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async { [weak self] in
                self?.fileOperation.isActive = true
                self?.fileOperation.totalCount = urls.count
                self?.fileOperation.processedCount = 0
            }

            let destAccessed = destinationDir.startAccessingSecurityScopedResource()
            defer { if destAccessed { destinationDir.stopAccessingSecurityScopedResource() } }

            var successfullyMoved: Set<URL> = []
            let fm = FileManager.default

            do {
                var processedCount = 0
                for sourceURL in urls {
                    if self.fileOperation.cancellationToken != operationID { break }

                    let fileName = sourceURL.lastPathComponent
                    let ext = sourceURL.pathExtension.lowercased()
                    let isJpeg = ext == "jpg" || ext == "jpeg"

                    if isJpeg {
                        do {
                            _ = try self.moveOrCopyImagePair(jpegURL: sourceURL, to: destinationDir, isCopy: false)
                            successfullyMoved.insert(sourceURL)
                            if let cr2Source = self.findCompanionCR2(for: sourceURL) {
                                successfullyMoved.insert(cr2Source)
                            }
                        } catch {
                            print("Error moving JPEG pair \(fileName): \(error)")
                        }
                    } else {
                        let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()

                        let originalName = sourceURL.deletingPathExtension().lastPathComponent
                        var finalURL = destinationDir.appendingPathComponent(fileName)

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
                            print("Error moving file \(fileName): \(error)")
                        }

                        if sourceAccessed {
                            sourceURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    processedCount += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.fileOperation.processedCount = processedCount
                        self?.fileOperation.progress = Double(processedCount) / Double(urls.count)
                        self?.fileOperation.currentFile = fileName
                    }
                }

                if !successfullyMoved.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.recordOperation(.move(sources: Array(successfullyMoved), destination: destinationDir))
                    }

                    DispatchQueue.main.async { [weak self] in
                        let nextFocus = self?.computeNextFocus(for: self?.activeItemURL ?? self?.folderContents.first?.url ?? URL(fileURLWithPath: "/"), excluding: successfullyMoved)
                        self?.folderContents.removeAll(where: { successfullyMoved.contains($0.url) })
                        self?.selectedItemURLs.subtract(successfullyMoved)
                        if let next = nextFocus {
                            self?.activeItemURL = next
                            self?.selectedItemURLs = [next]
                        } else {
                            self?.activeItemURL = nil
                        }
                        self?.fileOperation.reset()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.fileOperation.reset()
                    }
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
        let renamingURLs = Set(moves.map { $0.0 })

        let operationID = UUID()
        fileOperation.cancellationToken = operationID
        fileOperation.isActive = true
        fileOperation.totalCount = moves.count * 2

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { continuation.resume(); return }

                let parentAccessed = parentFolder?.startAccessingSecurityScopedResource() ?? false
                defer { if parentAccessed { parentFolder?.stopAccessingSecurityScopedResource() } }

                do {
                    var processedCount = 0
                    var tempMoves: [(URL, URL)] = []

                    // Phase 1: Rename to temporary names to avoid intra-batch collisions
                    for (source, destination) in moves {
                        if self.fileOperation.cancellationToken != operationID { break }

                        if source == destination {
                            DispatchQueue.main.async { [weak self] in
                                self?.fileOperation.processedCount += 1
                                self?.fileOperation.progress = Double(self?.fileOperation.processedCount ?? 0) / Double(moves.count * 2)
                            }
                            continue
                        }

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

                        processedCount += 1
                        DispatchQueue.main.async { [weak self] in
                            self?.fileOperation.processedCount = processedCount
                            self?.fileOperation.progress = Double(processedCount) / Double(moves.count * 2)
                            self?.fileOperation.currentFile = source.lastPathComponent
                        }
                    }

                    // Phase 2: Rename to final names
                    for (tempURL, destination) in tempMoves {
                        if self.fileOperation.cancellationToken != operationID { break }

                        do {
                            if FileManager.default.fileExists(atPath: destination.path) {
                                print("File already exists at destination: \(destination.path)")
                                processedCount += 1
                                DispatchQueue.main.async { [weak self] in
                                    self?.fileOperation.processedCount = processedCount
                                    self?.fileOperation.progress = Double(processedCount) / Double(moves.count * 2)
                                }
                                continue
                            }
                            try FileManager.default.moveItem(at: tempURL, to: destination)
                        } catch {
                            print("Error renaming temp file to \(destination.lastPathComponent): \(error)")
                        }

                        processedCount += 1
                        DispatchQueue.main.async { [weak self] in
                            self?.fileOperation.processedCount = processedCount
                            self?.fileOperation.progress = Double(processedCount) / Double(moves.count * 2)
                            self?.fileOperation.currentFile = destination.lastPathComponent
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        if let url = self?.currentFolderURL {
                            let nextFocus = focusURL.flatMap { self?.computeNextFocus(for: $0, excluding: renamingURLs) }
                            self?.loadFolder(url: url, sidebarManager: nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let next = nextFocus {
                                    self?.activeItemURL = next
                                    self?.selectedItemURLs = [next]
                                }
                            }
                        }
                        self?.fileOperation.reset()
                        continuation.resume()
                    }
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
        preloadTask?.cancel()

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
        thumbnailLoader.maxTasks = isLocalFolder ? 24 : 6

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

                // Pre-generación inteligente: Fase 1 (visibles) + Fase 2 (rest)
                let itemsToPreload = sortedItems.filter { !$0.isDirectory }
                let visibleCount = 40
                let (visibleItems, restItems) = (
                    Array(itemsToPreload.prefix(visibleCount)),
                    Array(itemsToPreload.dropFirst(visibleCount))
                )
                let loader = await MainActor.run { self.thumbnailLoader }

                await MainActor.run {
                    // Fase 1: Pre-generar ~40 visibles con prioridad alta
                    self.preloadTask = Task.detached(priority: .userInitiated) { [weak loader, isLocalFolder] in
                        guard let loader else { return }
                        for item in visibleItems {
                            guard !Task.isCancelled else { break }
                            await ThumbnailCache.load(item: item, using: loader)
                        }

                        // Fase 2 (precargar el resto) SOLO en folders locales.
                        // En remoto saturaría la red; el resto se carga bajo demanda al hacer scroll.
                        if isLocalFolder && !Task.isCancelled && !restItems.isEmpty {
                            Task.detached(priority: .utility) {
                                for item in restItems {
                                    guard !Task.isCancelled else { break }
                                    await ThumbnailCache.load(item: item, using: loader)
                                }
                            }
                        }
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
        // 1. Clear navigation & history
        navigationHistory.removeAll()
        navigationIndex = -1
        folderHistory.removeAll()

        // 2. Clear undo/redo history (aggressive memory cleanup)
        undoHistory.removeAll()
        canUndo = false

        // 3. Clear selections & temp states
        selectedItemURLs.removeAll()
        selectionAnchorURL = nil
        selectionAnchorIndex = nil
        selectionBaseURLs.removeAll()

        // 4. Clear compare mode
        compareImageURLs = nil

        // 5. Clear metadata cache
        metadataString = ""

        // 6. Close any open dialogs/alerts
        isShowingProperties = false
        propertiesURL = nil
        isShowingSingleRenameAlert = false
        isShowingBulkRenameAlert = false
        notificationMessage = nil

        // 7. Reload current folder to refresh display
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

        let operationID = UUID()
        fileOperation.cancellationToken = operationID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async { [weak self] in
                self?.fileOperation.isActive = true
                self?.fileOperation.totalCount = blocks.count
                self?.fileOperation.processedCount = 0
            }

            var processedCount = 0
            for block in blocks {
                if self.fileOperation.cancellationToken != operationID { break }

                let partNum = self.nextAvailablePartitionNumber(in: folderURL, baseName: folderName)
                let partFolderName = "\(folderName)_\(partNum)"
                let partFolderURL = folderURL.appendingPathComponent(partFolderName)

                try? FileManager.default.createDirectory(at: partFolderURL,
                                                         withIntermediateDirectories: false)

                let imageURLs = block.map { $0.url }

                // Realizar movimiento de forma sincrónica en el background thread
                do {
                    let fm = FileManager.default
                    var successfullyMoved: Set<URL> = []

                    for sourceURL in imageURLs {
                        let ext = sourceURL.pathExtension.lowercased()
                        let isJpeg = ext == "jpg" || ext == "jpeg"

                        if isJpeg {
                            do {
                                _ = try self.moveOrCopyImagePair(jpegURL: sourceURL, to: partFolderURL, isCopy: false)
                                successfullyMoved.insert(sourceURL)
                                if let cr2Source = self.findCompanionCR2(for: sourceURL) {
                                    successfullyMoved.insert(cr2Source)
                                }
                            } catch {
                                print("Error moving JPEG pair \(sourceURL.lastPathComponent): \(error)")
                            }
                        } else {
                            let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()

                            let originalName = sourceURL.deletingPathExtension().lastPathComponent
                            var finalURL = partFolderURL.appendingPathComponent(sourceURL.lastPathComponent)

                            var counter = 1
                            while fm.fileExists(atPath: finalURL.path) {
                                let newName = ext.isEmpty ? "\(originalName)_\(counter)" : "\(originalName)_\(counter).\(ext)"
                                finalURL = partFolderURL.appendingPathComponent(newName)
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
                    }

                    if !successfullyMoved.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            self?.recordOperation(.move(sources: Array(successfullyMoved), destination: partFolderURL))
                        }
                    }
                } catch {
                    print("Error in partition block: \(error)")
                }

                processedCount += 1
                DispatchQueue.main.async { [weak self] in
                    self?.fileOperation.processedCount = processedCount
                    self?.fileOperation.progress = Double(processedCount) / Double(blocks.count)
                    self?.fileOperation.currentFile = "\(partFolderName)"
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.loadFolder(url: folderURL, sidebarManager: nil)
                self?.fileOperation.reset()
            }
        }
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
                    let fm = FileManager.default
                    let originFolder = sources.first?.deletingLastPathComponent()

                    // Move ALL files back to their original locations
                    for source in sources {
                        let movedFileURL = destination.appendingPathComponent(source.lastPathComponent)
                        try fm.moveItem(at: movedFileURL, to: source)

                        // If this is a JPEG, check for associated CR2 and move it back too
                        let ext = source.pathExtension.lowercased()
                        if ext == "jpg" || ext == "jpeg" {
                            let baseName = source.deletingPathExtension().lastPathComponent
                            let cr2SourceURL = source.deletingLastPathComponent().appendingPathComponent("\(baseName).cr2")
                            let cr2MovedURL = destination.appendingPathComponent("\(baseName).cr2")

                            if fm.fileExists(atPath: cr2MovedURL.path) {
                                do {
                                    try fm.moveItem(at: cr2MovedURL, to: cr2SourceURL)
                                } catch {
                                    print("Warning: Could not undo CR2 file move: \(error)")
                                }
                            }
                        }
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
                    let fm = FileManager.default
                    // Delete ALL copied files
                    for destination in destinations {
                        try fm.removeItem(at: destination)

                        // If this is a JPEG, check for associated CR2 and delete it too
                        let ext = destination.pathExtension.lowercased()
                        if ext == "jpg" || ext == "jpeg" {
                            let baseName = destination.deletingPathExtension().lastPathComponent
                            let cr2URL = destination.deletingLastPathComponent().appendingPathComponent("\(baseName).cr2")

                            if fm.fileExists(atPath: cr2URL.path) {
                                do {
                                    try fm.removeItem(at: cr2URL)
                                } catch {
                                    print("Warning: Could not undo CR2 file deletion: \(error)")
                                }
                            }
                        }
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
                    let fm = FileManager.default
                    let parent = source.deletingLastPathComponent()
                    let oldURL = parent.appendingPathComponent(oldName)
                    try fm.moveItem(at: source, to: oldURL)

                    // If this is a JPEG, check for associated CR2 and rename it back too
                    let ext = oldName.components(separatedBy: ".").last?.lowercased() ?? ""
                    if ext == "jpg" || ext == "jpeg" {
                        let oldBaseName = (oldName as NSString).deletingPathExtension
                        let newBaseName = source.deletingPathExtension().lastPathComponent
                        let cr2CurrentURL = parent.appendingPathComponent("\(newBaseName).cr2")
                        let cr2OldURL = parent.appendingPathComponent("\(oldBaseName).cr2")

                        if fm.fileExists(atPath: cr2CurrentURL.path) {
                            do {
                                try fm.moveItem(at: cr2CurrentURL, to: cr2OldURL)
                            } catch {
                                print("Warning: Could not undo CR2 file rename: \(error)")
                            }
                        }
                    }

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
