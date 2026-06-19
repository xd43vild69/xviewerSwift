//
//  ContentView.swift
//  xviewerSwift
//
//  Created by D13 on 17/06/26.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

enum SortOrder: String, CaseIterable {
    case name
    case date
    case size
}

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let creationDate: Date
    let fileSize: Int64
}

class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var activeTasks = 0
    private let maxTasks = 4
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activeTasks < maxTasks {
                activeTasks += 1
                lock.unlock()
                continuation.resume()
            } else {
                pendingContinuations.append(continuation)
                lock.unlock()
            }
        }
    }
    
    func signal() {
        lock.lock()
        if !pendingContinuations.isEmpty {
            let continuation = pendingContinuations.removeFirst()
            lock.unlock()
            continuation.resume()
        } else {
            activeTasks -= 1
            lock.unlock()
        }
    }
}

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    
    private init() {
        cache.countLimit = 1000 // ~100 MB max for 160x160 thumbnails
    }
    
    func get(for url: URL) -> NSImage? {
        return cache.object(forKey: url as NSURL)
    }
    
    func set(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

struct FileItemView: View {
    let url: URL
    @State private var thumbnail: NSImage?
    
    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
                    .task(id: url) {
                        await loadThumbnail()
                    }
            }
        }
    }
    
    private func loadThumbnail() async {
        if let cached = ThumbnailCache.shared.get(for: url) {
            self.thumbnail = cached
            return
        }
        
        await ThumbnailLoader.shared.wait()
        defer {
            ThumbnailLoader.shared.signal()
        }
        
        if Task.isCancelled { return }
        
        if let cached = ThumbnailCache.shared.get(for: url) {
            self.thumbnail = cached
            return
        }
        
        let size = CGSize(width: 160, height: 160)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )
        
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let nsImage = representation.nsImage
            ThumbnailCache.shared.set(nsImage, for: self.url)
            self.thumbnail = nsImage
        } catch {
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160
                ]
                if let imageSource = CGImageSourceCreateWithURL(self.url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    return NSImage(cgImage: cgImage, size: .zero)
                }
                return nil
            }.value
            
            if let img = img {
                ThumbnailCache.shared.set(img, for: self.url)
                self.thumbnail = img
            }
        }
    }
}

class ImmersiveWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class ImmersiveWindowController {
    static let shared = ImmersiveWindowController()
    private var window: ImmersiveWindow?
    
    func show<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        if let existingWindow = window {
            if let hostingView = existingWindow.contentView as? NSHostingView<Content> {
                hostingView.rootView = content()
            } else {
                existingWindow.contentView = NSHostingView(rootView: content())
            }
            return
        }
        
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        
        let newWindow = ImmersiveWindow(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        newWindow.level = .screenSaver
        newWindow.backgroundColor = .black
        newWindow.isOpaque = true
        newWindow.hasShadow = false
        newWindow.isReleasedWhenClosed = false
        newWindow.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        
        newWindow.contentView = NSHostingView(rootView: content())
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func hide() {
        window?.close()
        window = nil
    }
}

class ZoomState: ObservableObject {
    @Published var currentZoom: CGFloat = 0.0
    @Published var totalZoom: CGFloat = 1.0
    @Published var currentOffset: CGSize = .zero
    @Published var totalOffset: CGSize = .zero
    
    private var monitor: Any?
    
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            if self.totalZoom > 1.0 {
                DispatchQueue.main.async {
                    self.totalOffset.width += event.scrollingDeltaX
                    self.totalOffset.height += event.scrollingDeltaY
                }
                return nil // Consume scroll event
            }
            return event
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    func reset() {
        totalZoom = 1.0
        currentZoom = 0.0
        totalOffset = .zero
        currentOffset = .zero
    }
}

struct FullScreenImageView: View {
    let url: URL
    let onClose: () -> Void
    let navigateImage: (Int) -> Void
    
    @State private var nsImage: NSImage?
    @State private var isInverted = false
    @State private var rotationAngle: Double = 0.0
    @StateObject private var zoomState = ZoomState()
    @State private var showUI: Bool = true
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            
            if let image = nsImage {
                Group {
                    if isInverted {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                    .rotationEffect(.degrees(rotationAngle), anchor: .center)
                    .animation(.easeInOut(duration: 0.2), value: rotationAngle)
                    .padding()
                    .scaleEffect(max(0.1, zoomState.totalZoom + zoomState.currentZoom))
                    .offset(x: zoomState.totalOffset.width + zoomState.currentOffset.width, y: zoomState.totalOffset.height + zoomState.currentOffset.height)
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomState.currentZoom = value - 1
                            }
                            .onEnded { value in
                                zoomState.totalZoom += zoomState.currentZoom
                                zoomState.currentZoom = 0
                                if zoomState.totalZoom <= 1.0 {
                                    withAnimation(.spring()) {
                                        zoomState.totalZoom = 1.0
                                        zoomState.totalOffset = .zero
                                    }
                                } else if zoomState.totalZoom > 5.0 {
                                    withAnimation(.spring()) {
                                        zoomState.totalZoom = 5.0
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if zoomState.totalZoom > 1.0 {
                                    zoomState.currentOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                if zoomState.totalZoom > 1.0 {
                                    zoomState.totalOffset.width += zoomState.currentOffset.width
                                    zoomState.totalOffset.height += zoomState.currentOffset.height
                                    zoomState.currentOffset = .zero
                                }
                            }
                    )
                    .onTapGesture { onClose() }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            
            if showUI {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { 
                            if rotationAngle != 0.0 {
                                withAnimation(nil) { rotationAngle = 0.0 }
                            } else {
                                onClose() 
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                                .padding()
                        }
                        .buttonStyle(PlainButtonStyle())
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        if let image = nsImage {
                            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(8)
                                .padding()
                        }
                    }
                }
            } else {
                // Invisible button to capture Escape when UI is hidden
                Button(action: { onClose() }) { Text("") }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
            }
            
            Button(action: { showUI.toggle() }) { Text("") }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: [])
                .opacity(0)
            
            Button(action: { navigateImage(-1) }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
            
            Button(action: { navigateImage(1) }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { navigateImage(-1) }) { Text("") }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
            
            Button(action: { navigateImage(1) }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { rotationAngle -= 90.0 }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .opacity(0)

            Button(action: { rotationAngle += 90.0 }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .opacity(0)

            Button(action: { withAnimation(nil) { rotationAngle = 0.0 } }) { Text("") }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                
            Button(action: { isInverted.toggle() }) { Text("") }
                .keyboardShortcut("i", modifiers: [.command])
                .opacity(0)
        }
        .zIndex(1)
        .onAppear { loadImage(from: url) }
        .onChange(of: url) { oldURL, newURL in
            nsImage = nil
            zoomState.reset()
            withAnimation(nil) { rotationAngle = 0.0 }
            loadImage(from: newURL)
        }
    }
    
    private func loadImage(from url: URL) {
        DispatchQueue.global(qos: .userInteractive).async {
            if let img = NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    self.nsImage = img
                }
            }
        }
    }
}

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { current, _ in current }
    }
}

struct GridItemCell: View {
    let item: FileItem
    @Binding var selectedItemURLs: Set<URL>
    @Binding var activeItemURL: URL?
    @Binding var fullScreenImageURL: URL?
    @Binding var currentSortOrder: SortOrder
    let loadFolderAction: (URL) -> Void
    let moveItemAction: (URL) -> Void
    let createNewFolderAction: () -> Void
    let openWithKritaAction: (URL) -> Void
    let renameItemAction: (URL) -> Void
    let showPropertiesAction: (URL) -> Void
    let isBookmarked: Bool
    let toggleBookmarkAction: () -> Void
    let isSingleSelection: Bool
    
    var body: some View {
        VStack {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.blue)
            } else {
                FileItemView(url: item.url)
            }
            Text(item.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedItemURLs.contains(item.url) ? Color.blue.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedItemURLs.contains(item.url) ? Color.blue : Color.clear, lineWidth: 2)
        )
        .help(item.url.lastPathComponent)
        .onTapGesture(count: 2) {
            activeItemURL = item.url
            selectedItemURLs = [item.url]
            if item.isDirectory {
                loadFolderAction(item.url)
            } else {
                fullScreenImageURL = item.url
            }
        }
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if selectedItemURLs.contains(item.url) {
                    selectedItemURLs.remove(item.url)
                } else {
                    selectedItemURLs.insert(item.url)
                }
            } else {
                selectedItemURLs = [item.url]
            }
            activeItemURL = item.url
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FramePreferenceKey.self,
                    value: [item.url: geo.frame(in: .named("GridSpace"))]
                )
            }
        )
        .contextMenu {
            Button { currentSortOrder = .name } label: {
                Label("Order by name", systemImage: currentSortOrder == .name ? "checkmark" : "")
            }
            Button { currentSortOrder = .date } label: {
                Label("Order by date", systemImage: currentSortOrder == .date ? "checkmark" : "")
            }
            Button { currentSortOrder = .size } label: {
                Label("Order by size", systemImage: currentSortOrder == .size ? "checkmark" : "")
            }
            Divider()
            Button { moveItemAction(item.url) } label: {
                Label("Move To...", systemImage: "folder")
            }
            Button { createNewFolderAction() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            if item.isDirectory {
                Divider()
                Button { toggleBookmarkAction() } label: {
                    Label(isBookmarked ? "Remove from Bookmarks" : "Add to Bookmarks", systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
                }
            }
            if !item.isDirectory {
                Divider()
                Button { openWithKritaAction(item.url) } label: {
                    Label("Open with Krita", systemImage: "paintpalette")
                }
            }
            Divider()
            Button { renameItemAction(item.url) } label: {
                Label("Rename...", systemImage: "pencil.line")
            }
            if !item.isDirectory {
                Divider()
                Button { showPropertiesAction(item.url) } label: {
                    Label("Properties", systemImage: "info.circle")
                }
                .disabled(!isSingleSelection)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var sidebarManager = SidebarManager()
    @State private var isShowingFolderPicker = false
    @State private var sidebarSelection: URL?
    @State private var currentFolderURL: URL?
    @State private var folderContents: [FileItem] = []
    @State private var fullScreenImageURL: URL?
    @State private var selectedItemURLs: Set<URL> = []
    @State private var activeItemURL: URL?
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragInitialSelection: Set<URL> = []
    @State private var currentColumnCount: Int = 1
    @State private var metadataString: String = ""
    @State private var currentSortOrder: SortOrder = .name
    
    @State private var isShowingProperties = false
    @State private var propertiesURL: URL?
    
    @State private var isShowingSingleRenameAlert = false
    @State private var singleRenameBaseName: String = ""
    @State private var itemToRename: URL?

    @State private var isShowingBulkRenameAlert = false
    @State private var bulkRenameBaseName: String = ""
    @State private var showCopiedFeedback: Bool = false
    @State private var folderHistory: [URL: URL] = [:]

    private var imageItems: [FileItem] {
        folderContents.filter { !$0.isDirectory }
    }

    private var leftPanel: some View {
        SidebarNavigationView(manager: sidebarManager, selectedFolderURL: $sidebarSelection)
            .fileImporter(
                isPresented: $isShowingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let rawURL = urls.first {
                        let secureURL = sidebarManager.makeSecureURL(rawURL)
                        sidebarSelection = secureURL
                        saveBookmark(for: secureURL)
                    }
                case .failure(let error):
                    print("Error selecting folder: \(error.localizedDescription)")
                }
            }
    }
    
    @ViewBuilder
    private var dragOverlay: some View {
        if let start = dragStart, let current = dragCurrent {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            Rectangle()
                .fill(Color.blue.opacity(0.2))
                .border(Color.blue, width: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
    
    private func updateSelectionFromDrag() {
        guard let start = dragStart, let current = dragCurrent else { return }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        
        var newSelection = dragInitialSelection
        for (url, frame) in itemFrames {
            if rect.intersects(frame) {
                newSelection.insert(url)
            }
        }
        selectedItemURLs = newSelection
        if let first = newSelection.first {
            activeItemURL = first
        }
    }

    private var rightPanel: some View {
        GeometryReader { geometry in
            let columns = max(1, Int(geometry.size.width / 116))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100)), count: columns), spacing: 16) {
                        ForEach(folderContents) { item in
                            GridItemCell(
                                item: item,
                                selectedItemURLs: $selectedItemURLs,
                                activeItemURL: $activeItemURL,
                                fullScreenImageURL: $fullScreenImageURL,
                                currentSortOrder: $currentSortOrder,
                                loadFolderAction: { url in
                                    sidebarSelection = nil
                                    loadFolder(url: url)
                                },
                                moveItemAction: { url in
                                    moveItem(url)
                                },
                                createNewFolderAction: {
                                    createNewFolder()
                                },
                                openWithKritaAction: { url in
                                    openWithKrita(url)
                                },
                                renameItemAction: { url in
                                    promptSingleRename(for: url)
                                },
                                showPropertiesAction: { url in
                                    propertiesURL = url
                                    isShowingProperties = true
                                },
                                isBookmarked: sidebarManager.bookmarks.contains(where: { $0.url == item.url }),
                                toggleBookmarkAction: {
                                    if sidebarManager.bookmarks.contains(where: { $0.url == item.url }) {
                                        sidebarManager.unpinFolder(url: item.url)
                                    } else {
                                        sidebarManager.pinFolder(url: item.url)
                                    }
                                },
                                isSingleSelection: selectedItemURLs.count == 1 && selectedItemURLs.contains(item.url)
                            )
                            .id(item.url)
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: "GridSpace")
                .onPreferenceChange(FramePreferenceKey.self) { frames in
                    itemFrames = frames
                }
                .overlay(dragOverlay)
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = value.startLocation
                                dragInitialSelection = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) ? selectedItemURLs : []
                            }
                            dragCurrent = value.location
                            updateSelectionFromDrag()
                        }
                        .onEnded { _ in
                            dragStart = nil
                            dragCurrent = nil
                        }
                )
                .onChange(of: activeItemURL) { oldURL, newURL in
                    if let url = newURL {
                        proxy.scrollTo(url)
                    }
                }
                .onChange(of: folderContents) { _, newContents in
                    if !newContents.isEmpty, let url = activeItemURL {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(url)
                        }
                    }
                }
            }
            .onChange(of: columns) { oldValue, newValue in
                currentColumnCount = newValue
            }
            .onChange(of: currentSortOrder) { oldOrder, newOrder in
                folderContents = sortItems(folderContents)
            }
            .onAppear {
                currentColumnCount = columns
                if let url = restoreBookmark() {
                    sidebarSelection = url
                } else {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    sidebarSelection = home
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItemURLs.removeAll()
            activeItemURL = nil
        }
        .contextMenu {
            Button { currentSortOrder = .name } label: {
                Label("Order by name", systemImage: currentSortOrder == .name ? "checkmark" : "")
            }
            Button { currentSortOrder = .date } label: {
                Label("Order by date", systemImage: currentSortOrder == .date ? "checkmark" : "")
            }
            Button { currentSortOrder = .size } label: {
                Label("Order by size", systemImage: currentSortOrder == .size ? "checkmark" : "")
            }
            Divider()
            Button { createNewFolder() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button { promptBulkRename() } label: {
                Label("Rename All...", systemImage: "pencil.line")
            }
        }
    }

    private var shortcutsGroup: some View {
        Group {
            Button(action: { navigateUp() }) { Text("") }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .opacity(0)
                
            Button(action: { handleUpArrow() }) { Text("") }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { handleDownArrow() }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { handleLeftArrow() }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { handleRightArrow() }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { handleEnter() }) { Text("") }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                
            Button(action: { handleEnter() }) { Text("") }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                
            Button(action: { handleEnter() }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .opacity(0)
                
            Button(action: { copySelectedItemToClipboard() }) { Text("") }
                .keyboardShortcut("c", modifiers: [.command])
                .opacity(0)
                
            Button(action: { pasteFromClipboard() }) { Text("") }
                .keyboardShortcut("v", modifiers: [.command])
                .opacity(0)
                
            Button(action: { deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: []) // Backspace
                .opacity(0)
                
            Button(action: { deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: [.command]) // Cmd + Backspace
                .opacity(0)
                
            Button(action: { deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(.delete, modifiers: []) // Forward Delete
                .opacity(0)
                
            Button(action: { deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(.delete, modifiers: [.command]) // Cmd + Forward Delete
                .opacity(0)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let url = activeItemURL ?? currentFolderURL {
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .onTapGesture {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(url.path, forType: .string)
                            
                            withAnimation {
                                showCopiedFeedback = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                withAnimation {
                                    showCopiedFeedback = false
                                }
                            }
                        }
                        .opacity(showCopiedFeedback ? 0.3 : 1.0)
                }
                
                if showCopiedFeedback {
                    Text("(Copied to clipboard)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                
                Spacer()
                
                Text(metadataString)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    var body: some View {
        GeometryReader { mainGeometry in
            ZStack {
                HStack(spacing: 0) {
                    leftPanel
                        .frame(width: mainGeometry.size.width * 0.1)
                    rightPanel
                }
                
                // Full screen presentation is now handled via .onChange of fullScreenImageURL

                
                shortcutsGroup
            }
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
            .frame(width: mainGeometry.size.width, height: mainGeometry.size.height)
        }
        .preferredColorScheme(.dark)
        .onChange(of: sidebarSelection) { oldURL, newURL in
            if let url = newURL {
                loadFolder(url: url)
            }
        }
        .onChange(of: fullScreenImageURL) { oldURL, newURL in
            if let url = newURL {
                ImmersiveWindowController.shared.show {
                    FullScreenImageView(url: url, onClose: {
                        fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        navigateFullScreen(direction: direction)
                    })
                }
            } else {
                ImmersiveWindowController.shared.hide()
            }
        }
        .onChange(of: activeItemURL) { oldURL, newURL in
            updateMetadata(for: newURL)
        }
        .onOpenURL { url in
            let dir = url.deletingLastPathComponent()
            sidebarSelection = dir
            activeItemURL = url
            selectedItemURLs = [url]
            fullScreenImageURL = url
        }
        .sheet(isPresented: $isShowingProperties) {
            if let url = propertiesURL {
                PropertiesView(url: url)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    isShowingFolderPicker = true
                }) {
                    Label("Select Folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
    
    private func copySelectedItemToClipboard() {
        guard !selectedItemURLs.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(selectedItemURLs.map { $0 as NSURL })
    }
    
    private func pasteFromClipboard() {
        guard let targetFolder = currentFolderURL else { return }
        let pasteboard = NSPasteboard.general
        
        var pastedSomething = false
        
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for sourceURL in urls where sourceURL.isFileURL {
                let destinationURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if !FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        pastedSomething = true
                    }
                } catch {
                    print("Error copying file: \(error)")
                }
            }
        } else if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
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
        }
        
        if pastedSomething {
            loadFolder(url: targetFolder)
        } else {
            NSSound.beep() // Provide feedback if paste failed or was empty
        }
    }
    
    private func deleteSelectedItem() {
        var targets = selectedItemURLs
        if let fsURL = fullScreenImageURL { targets.insert(fsURL) }
        guard !targets.isEmpty else { return }
        
        let allItems = folderContents.filter { !$0.isDirectory }
        let nextURL = allItems.first(where: { !targets.contains($0.url) })?.url
        
        do {
            for url in targets {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    try FileManager.default.removeItem(at: url)
                }
            }
            folderContents.removeAll(where: { targets.contains($0.url) })
            selectedItemURLs = []
            if let next = nextURL {
                selectedItemURLs = [next]
                activeItemURL = next
            } else {
                activeItemURL = nil
            }
            if fullScreenImageURL != nil { fullScreenImageURL = nextURL }
        } catch {
            print("Error deleting file: \(error)")
            NSSound.beep()
        }
    }
    
    private func moveItem(_ url: URL) {
        var targets = selectedItemURLs
        if !targets.contains(url) { targets.insert(url) }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose destination folder"
        
        if panel.runModal() == .OK, let destinationURL = panel.url {
            let allItems = folderContents.filter { !$0.isDirectory }
            let nextURL = allItems.first(where: { !targets.contains($0.url) })?.url
            
            do {
                for tURL in targets {
                    let finalURL = destinationURL.appendingPathComponent(tURL.lastPathComponent)
                    try FileManager.default.moveItem(at: tURL, to: finalURL)
                }
                folderContents.removeAll(where: { targets.contains($0.url) })
                selectedItemURLs = []
                if let next = nextURL {
                    selectedItemURLs = [next]
                    activeItemURL = next
                } else {
                    activeItemURL = nil
                }
                if fullScreenImageURL != nil { fullScreenImageURL = nextURL }
            } catch {
                print("Error moving file: \(error)")
                NSSound.beep()
            }
        }
    }
    
    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "lastFolderBookmark")
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    private func restoreBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "lastFolderBookmark") else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                saveBookmark(for: url)
            }
            return url
        } catch {
            print("Failed to restore secure last folder bookmark: \(error)")
            return nil
        }
    }
    
    private func updateMetadata(for url: URL?) {
        guard let url = url else {
            metadataString = ""
            return
        }
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            metadataString = "Folder: \(url.lastPathComponent)"
            return
        }
        
        let name = url.lastPathComponent
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
        
        metadataString = "\(name)  |  \(sizeStr)\(dimensionsStr)"
    }
    
    private func createNewFolder() {
        guard let currentDir = currentFolderURL else { return }
        
        let alert = NSAlert()
        alert.messageText = "Create New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = "New Folder"
        alert.accessoryView = textField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }
            
            let newURL = currentDir.appendingPathComponent(folderName)
            do {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true, attributes: nil)
                loadFolder(url: currentDir) // Refresh the view
            } catch {
                print("Error creating folder: \(error)")
                NSSound.beep()
            }
        }
    }
    
    private func openWithKrita(_ url: URL) {
        var targets = selectedItemURLs
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
    
    private func promptSingleRename(for url: URL) {
        let baseName = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "Enter a new name (extension will be preserved):"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = baseName
        alert.accessoryView = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty && newName != baseName {
                executeSingleRename(originalURL: url, newBaseName: newName)
            }
        }
    }

    private func promptBulkRename() {
        let alert = NSAlert()
        alert.messageText = "Batch Rename All Files"
        alert.informativeText = "Enter the base name. Files will be named 'basename_0000X':"
        alert.addButton(withTitle: "Rename All")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                executeBulkRename(baseName: newName)
            }
        }
    }

    private func executeSingleRename(originalURL: URL, newBaseName: String) {
        let directory = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension
        let newURL = ext.isEmpty ? directory.appendingPathComponent(newBaseName) : directory.appendingPathComponent("\(newBaseName).\(ext)")
        
        Task { await processRenames(moves: [(originalURL, newURL)]) }
    }

    private func executeBulkRename(baseName: String) {
        guard let dir = currentFolderURL else { return }
        let filesToRename = folderContents.filter { !$0.isDirectory }
        
        var moves: [(URL, URL)] = []
        for (index, file) in filesToRename.enumerated() {
            let originalURL = file.url
            let ext = originalURL.pathExtension
            let sequenceStr = String(format: "%05d", index + 1)
            let newFileName = ext.isEmpty ? "\(baseName)_\(sequenceStr)" : "\(baseName)_\(sequenceStr).\(ext)"
            let newURL = dir.appendingPathComponent(newFileName)
            moves.append((originalURL, newURL))
        }
        
        Task { await processRenames(moves: moves) }
    }

    private func processRenames(moves: [(URL, URL)]) async {
        let parentFolder = currentFolderURL
        
        await Task.detached(priority: .userInitiated) {
            for (source, destination) in moves {
                let itemAccessed = source.startAccessingSecurityScopedResource()
                do {
                    // Check if file exists to prevent throwing or overwrite implicitly.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        print("File already exists at destination: \(destination.path)")
                        continue
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch {
                    print("POSIX/Sandbox Error renaming \(source.lastPathComponent): \(error)")
                }
                if itemAccessed {
                    source.stopAccessingSecurityScopedResource()
                }
            }
        }.value
        
        if let url = currentFolderURL {
            self.loadFolder(url: url)
        }
    }
    
    private func handleUpArrow() {
        if fullScreenImageURL == nil {
            navigateGridRow(direction: -1)
        }
    }
    
    private func handleDownArrow() {
        if fullScreenImageURL == nil {
            navigateGridRow(direction: 1)
        }
    }
    
    private func handleLeftArrow() {
        if fullScreenImageURL != nil {
            navigateFullScreen(direction: -1)
        } else {
            navigateGrid(direction: -1)
        }
    }
    
    private func handleRightArrow() {
        if fullScreenImageURL != nil {
            navigateFullScreen(direction: 1)
        } else {
            navigateGrid(direction: 1)
        }
    }
    
    private func navigateGridRow(direction: Int) {
        guard !folderContents.isEmpty else { return }
        guard let currentSelected = activeItemURL, let currentIndex = folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            if let url = folderContents.first?.url {
                activeItemURL = url
                selectedItemURLs = [url]
            }
            return
        }
        let newIndex = currentIndex + (direction * currentColumnCount)
        if newIndex >= 0 && newIndex < folderContents.count {
            activeItemURL = folderContents[newIndex].url; selectedItemURLs = [folderContents[newIndex].url]
        } else if newIndex < 0 {
            if let u = folderContents.first?.url { activeItemURL = u; selectedItemURLs = [u] }
        } else if newIndex >= folderContents.count {
            if let u = folderContents.last?.url { activeItemURL = u; selectedItemURLs = [u] }
        }
    }
    
    private func navigateGrid(direction: Int) {
        guard !folderContents.isEmpty else { return }
        guard let currentSelected = activeItemURL, let currentIndex = folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            if let url = folderContents.first?.url {
                activeItemURL = url
                selectedItemURLs = [url]
            }
            return
        }
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < folderContents.count {
            activeItemURL = folderContents[newIndex].url; selectedItemURLs = [folderContents[newIndex].url]
        }
    }
    
    private func navigateFullScreen(direction: Int) {
        guard let currentURL = fullScreenImageURL else { return }
        let images = imageItems
        guard let currentIndex = images.firstIndex(where: { $0.url == currentURL }) else { return }
        
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < images.count {
            let newURL = images[newIndex].url
            fullScreenImageURL = newURL
            activeItemURL = newURL
            selectedItemURLs = [newURL]
        }
    }
    
    private func handleEnter() {
        guard fullScreenImageURL == nil else { return }
        guard let selected = activeItemURL else { return }
        
        if let item = folderContents.first(where: { $0.url == selected }) {
            if item.isDirectory {
                sidebarSelection = nil
                loadFolder(url: item.url)
            } else {
                fullScreenImageURL = item.url
            }
        }
    }
    
    private func navigateUp() {
        guard let current = currentFolderURL else { return }
        let parentURL = current.deletingLastPathComponent()
        
        sidebarSelection = nil
        loadFolder(url: parentURL)
    }
    
    private func sortItems(_ items: [FileItem]) -> [FileItem] {
        return items.sorted {
            if $0.isDirectory && !$1.isDirectory { return true }
            if !$0.isDirectory && $1.isDirectory { return false }
            
            switch currentSortOrder {
            case .name:
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            case .date:
                return $0.creationDate > $1.creationDate
            case .size:
                return $0.fileSize > $1.fileSize
            }
        }
    }
    
    private func loadFolder(url: URL) {
        sidebarManager.recordRecentVisit(url: url)
        if let current = currentFolderURL, let active = activeItemURL {
            folderHistory[current] = active
        }
        
        currentFolderURL = url
        folderContents = []
        
        if let savedActive = folderHistory[url] {
            activeItemURL = savedActive
            selectedItemURLs = [savedActive]
        } else {
            activeItemURL = nil
            selectedItemURLs = []
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
                return
            }
            
            var batch: [FileItem] = []
            var allItems: [FileItem] = []
            
            for case let fileURL as URL in enumerator {
                var isDirectory = false
                var fileDate = Date.distantPast
                var fileSize: Int64 = 0
                
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey]) {
                    isDirectory = resourceValues.isDirectory ?? false
                    fileDate = resourceValues.creationDate ?? Date.distantPast
                    fileSize = Int64(resourceValues.fileSize ?? 0)
                }
                
                if !isDirectory {
                    let ext = fileURL.pathExtension.lowercased()
                    let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp"]
                    if imageExtensions.contains(ext) {
                        batch.append(FileItem(url: fileURL, isDirectory: false, creationDate: fileDate, fileSize: fileSize))
                    }
                } else {
                    batch.append(FileItem(url: fileURL, isDirectory: true, creationDate: fileDate, fileSize: fileSize))
                }
                
                if batch.count >= 100 {
                    allItems.append(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                    
                    let sortedItems = self.sortItems(allItems)
                    
                    DispatchQueue.main.async {
                        guard self.currentFolderURL == url else { return }
                        self.folderContents = sortedItems
                        if self.activeItemURL == nil {
                            if let u = sortedItems.first?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
                        }
                    }
                }
            }
            
            if !batch.isEmpty || allItems.isEmpty {
                allItems.append(contentsOf: batch)
                let sortedItems = self.sortItems(allItems)
                
                DispatchQueue.main.async {
                    guard self.currentFolderURL == url else { return }
                    self.folderContents = sortedItems
                    if self.activeItemURL == nil {
                        if let u = sortedItems.first?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
