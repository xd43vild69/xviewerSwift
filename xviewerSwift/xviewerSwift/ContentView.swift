//
//  ContentView.swift
//  xviewerSwift
//
//  Created by D13 on 17/06/26.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import ImageIO

// MARK: - Environment Key for Per-Pane ThumbnailLoader
private struct ThumbnailLoaderKey: EnvironmentKey {
    static let defaultValue: ThumbnailLoader = ThumbnailLoader.shared
}

extension EnvironmentValues {
    var thumbnailLoader: ThumbnailLoader {
        get { self[ThumbnailLoaderKey.self] }
        set { self[ThumbnailLoaderKey.self] = newValue }
    }
}

enum SortOrder: String, CaseIterable {
    case name
    case date
    case size
}

struct FileItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let creationDate: Date
    let fileSize: Int64
    let isLocal: Bool
}

extension String {
    func sha256Hash() -> String {
        let inputData = Data(self.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

class ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()
    private let cacheDirectory: URL
    
    private init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cachesDir = paths[0].appendingPathComponent("com.d13.xviewerSwift")
        self.cacheDirectory = cachesDir.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }
    
    private func cacheKey(for url: URL, modificationDate: Date, fileSize: Int64) -> String {
        let path = url.standardizedFileURL.path
        let modDate = modificationDate.timeIntervalSince1970
        let compositeString = "\(path)_\(modDate)_\(fileSize)"
        return compositeString.sha256Hash()
    }
    
    func get(for url: URL, modificationDate: Date, fileSize: Int64) -> NSImage? {
        let key = cacheKey(for: url, modificationDate: modificationDate, fileSize: fileSize)
        let fileURL = cacheDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return NSImage(contentsOf: fileURL)
        }
        return nil
    }
    
    func set(_ image: NSImage, for url: URL, modificationDate: Date, fileSize: Int64) {
        let key = cacheKey(for: url, modificationDate: modificationDate, fileSize: fileSize)
        let fileURL = cacheDirectory.appendingPathComponent(key)
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
    
    func clear() {
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
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
    
    func clear() {
        cache.removeAllObjects()
    }
}

struct FileItemView: View {
    let item: FileItem
    @State private var thumbnail: NSImage?
    @Environment(\.isScrolling) private var isScrolling
    @Environment(\.thumbnailLoader) private var thumbnailLoader

    private struct TaskID: Equatable {
        let url: URL
        let isScrolling: Bool
    }

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
                    .task(id: TaskID(url: item.url, isScrolling: isScrolling)) {
                        guard !isScrolling else { return }
                        await loadThumbnail()
                    }
            }
        }
    }
    
    private func loadThumbnail() async {
        let url = item.url
        let isLocal = item.isLocal
        
        // 1. FAST-PATH (Memory Cache)
        if let cached = ThumbnailCache.shared.get(for: url) {
            self.thumbnail = cached
            return
        }
        
        // 2. FAST-PATH (Local Disk Cache) - 100% offline, zero network requests
        let diskCached = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if Task.isCancelled { return nil }
            return ThumbnailDiskCache.shared.get(for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
        }.value
        
        if Task.isCancelled { return }
        
        if let img = diskCached {
            ThumbnailCache.shared.set(img, for: url)
            self.thumbnail = img
            return
        }
        
        // 3. SLOW-PATH (Wait for scroll to end and fetch from network/generator)
        // Remote volumes (SMB/NFS) need longer settle time to avoid thrashing on fast scroll
        let debounceNs: UInt64 = isLocal ? 150_000_000 : 600_000_000
        do {
            try await Task.sleep(nanoseconds: debounceNs)
        } catch {
            return
        }
        
        if Task.isCancelled { return }
        
        do {
            try await thumbnailLoader.wait()
            defer {
                thumbnailLoader.signal()
            }
            
            if Task.isCancelled { return }
            
            // Check memory cache again in case another task loaded it while we were waiting
            if let cached = ThumbnailCache.shared.get(for: url) {
                self.thumbnail = cached
                return
            }
            
            if isLocal {
                let loadTask = Task.detached(priority: .userInitiated) { () -> NSImage? in
                    if Task.isCancelled { return nil }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160,
                        kCGImageSourceShouldCache: true
                    ]
                    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    if Task.isCancelled { return nil }
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        return NSImage(cgImage: cgImage, size: .zero)
                    }
                    return nil
                }
                
                let img = await withTaskCancellationHandler {
                    await loadTask.value
                } onCancel: {
                    loadTask.cancel()
                }
                
                if Task.isCancelled { return }
                
                if let img = img {
                    ThumbnailCache.shared.set(img, for: url)
                    Task.detached(priority: .background) {
                        ThumbnailDiskCache.shared.set(img, for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
                    }
                    self.thumbnail = img
                } else {
                    await loadQuickLookThumbnail()
                }
            } else {
                await loadQuickLookThumbnail()
            }
        } catch {
            // Cancelled while waiting for slot
        }
    }
    
    private func loadQuickLookThumbnail() async {
        let size = CGSize(width: 160, height: 160)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )
        
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            let img = representation.nsImage
            ThumbnailCache.shared.set(img, for: item.url)
            Task.detached(priority: .background) {
                ThumbnailDiskCache.shared.set(img, for: item.url, modificationDate: item.creationDate, fileSize: item.fileSize)
            }
            self.thumbnail = img
        } else if !item.isLocal {
            let ext = item.url.pathExtension
            let icon = NSWorkspace.shared.icon(forFileType: ext)
            ThumbnailCache.shared.set(icon, for: item.url)
            Task.detached(priority: .background) {
                ThumbnailDiskCache.shared.set(icon, for: item.url, modificationDate: item.creationDate, fileSize: item.fileSize)
            }
            self.thumbnail = icon
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
    @Published var rotationAngle: Double = 0.0
    
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    
    init() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
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
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let isCommandOnly = event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
            if isCommandOnly {
                if event.keyCode == 123 { // Left arrow
                    DispatchQueue.main.async { self.rotationAngle -= 90.0 }
                    return nil
                } else if event.keyCode == 124 { // Right arrow
                    DispatchQueue.main.async { self.rotationAngle += 90.0 }
                    return nil
                }
            }
            return event
        }
    }
    
    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    func reset() {
        totalZoom = 1.0
        currentZoom = 0.0
        totalOffset = .zero
        currentOffset = .zero
        withAnimation(nil) {
            rotationAngle = 0.0
        }
    }
}

struct FullScreenImageView: View {
    let url: URL
    let onClose: () -> Void
    let navigateImage: (Int) -> Void
    
    @State private var nsImage: NSImage?
    @State private var isInverted = false
    @State private var isBlackAndWhite = false
    @State private var isFlippedHorizontal = false
    @StateObject private var zoomState = ZoomState()
    @State private var showUI: Bool = true
    @State private var notificationMessage: String? = nil
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            
            if let image = nsImage {
                Group {
                    if isInverted && isBlackAndWhite {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                            .grayscale(1.0)
                    } else if isInverted {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                    } else if isBlackAndWhite {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .grayscale(1.0)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                    .scaleEffect(x: isFlippedHorizontal ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(zoomState.rotationAngle), anchor: .center)
                    .animation(.easeInOut(duration: 0.2), value: zoomState.rotationAngle)
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
                            if zoomState.rotationAngle != 0.0 {
                                withAnimation(nil) { zoomState.rotationAngle = 0.0 }
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
                
            Button(action: { withAnimation(nil) { zoomState.rotationAngle = 0.0 } }) { Text("") }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                
            Button(action: { isInverted.toggle() }) { Text("") }
                .keyboardShortcut("i", modifiers: [.command])
                .opacity(0)
                
            Button(action: { isFlippedHorizontal.toggle() }) { Text("") }
                .keyboardShortcut("h", modifiers: [.command])
                .opacity(0)
                
            Button(action: { isBlackAndWhite.toggle() }) { Text("") }
                .keyboardShortcut("b", modifiers: [.command])
                .opacity(0)
                
            Button(action: { copyToFavorites() }) { Text("") }
                .keyboardShortcut("m", modifiers: [.command])
                .opacity(0)
                
            if let message = notificationMessage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                            .padding()
                            .transition(.opacity)
                    }
                }
            }
        }
        .zIndex(1)
        .onAppear {
            loadImage(from: url) }
        .onChange(of: url) { oldURL, newURL in
            nsImage = nil
            zoomState.reset()
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
    
    private func copyToFavorites() {
        guard let favoritesURL = AppSettings.shared.favoritesURL else {
            showNotification("⚠️ Primero configura la ruta de Favoritos en la configuración")
            NSSound.beep()
            return
        }
        
        let destAccessed = favoritesURL.startAccessingSecurityScopedResource()
        defer { if destAccessed { favoritesURL.stopAccessingSecurityScopedResource() } }
        
        let sourceAccessed = url.startAccessingSecurityScopedResource()
        defer { if sourceAccessed { url.stopAccessingSecurityScopedResource() } }
        
        let fm = FileManager.default
        let originalName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        
        var finalURL = favoritesURL.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        var suffix = ""
        while fm.fileExists(atPath: finalURL.path) {
            suffix = "_\(counter)"
            let newName = ext.isEmpty ? "\(originalName)\(suffix)" : "\(originalName)\(suffix).\(ext)"
            finalURL = favoritesURL.appendingPathComponent(newName)
            counter += 1
        }
        
        // Check for associated RAW file
        var rawSourceURL: URL? = nil
        let possibleRawExtensions = ["cr2", "CR2", "raw", "RAW", "nef", "NEF", "arw", "ARW"]
        for rawExt in possibleRawExtensions {
            let tempRawURL = url.deletingPathExtension().appendingPathExtension(rawExt)
            if fm.fileExists(atPath: tempRawURL.path) {
                rawSourceURL = tempRawURL
                break
            }
        }
        
        var finalRawURL: URL? = nil
        if let rawSrc = rawSourceURL {
            let rawExt = rawSrc.pathExtension
            let newRawName = "\(originalName)\(suffix).\(rawExt)"
            finalRawURL = favoritesURL.appendingPathComponent(newRawName)
        }
        
        do {
            try fm.copyItem(at: url, to: finalURL)
            if let rawSrc = rawSourceURL, let rawDest = finalRawURL {
                try fm.copyItem(at: rawSrc, to: rawDest)
                showNotification("✅ Copiado a Favoritos (+ RAW)")
            } else {
                showNotification("✅ Copiado a Favoritos")
            }
        } catch {
            print("Error copying to favorites: \(error)")
            showNotification("❌ Error al copiar")
            NSSound.beep()
        }
    }
    
    private func showNotification(_ message: String) {
        withAnimation {
            notificationMessage = message
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                if notificationMessage == message {
                    notificationMessage = nil
                }
            }
        }
    }
}



struct RubberBandSelectionGesture: ViewModifier {
    @Binding var selectedItemURLs: Set<URL>
    @Binding var activeItemURL: URL?
    let folderContents: [FileItem]
    let columns: Int
    let viewportWidth: CGFloat

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragInitialSelection: Set<URL> = []

    func body(content: Content) -> some View {
        content
            .overlay {
                rubberBandOverlay
                    .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                            dragInitialSelection = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                                ? selectedItemURLs
                                : []
                        }
                        dragCurrent = value.location
                        applySelectionFromDrag()
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragCurrent = nil
                        dragInitialSelection = []
                    }
            )
    }

    @ViewBuilder
    private var rubberBandOverlay: some View {
        if let start = dragStart, let current = dragCurrent {
            let rect = dragRect(from: start, to: current)
            Rectangle()
                .fill(Color.blue.opacity(0.2))
                .border(Color.blue, width: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func dragRect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func applySelectionFromDrag() {
        guard let start = dragStart, let current = dragCurrent else { return }
        let rect = dragRect(from: start, to: current)
        let newSelection = selection(for: rect)

        guard newSelection != selectedItemURLs else { return }
        selectedItemURLs = newSelection
        if let first = newSelection.first {
            activeItemURL = first
        }
    }

    private func selection(for rect: CGRect) -> Set<URL> {
        var result = dragInitialSelection
        let itemCount = folderContents.count
        guard itemCount > 0, columns > 0 else { return result }

        let cellW = GridLayout.cellWidth(viewportWidth: viewportWidth, columns: columns)
        let rowStride = GridLayout.cellHeight + GridLayout.spacing
        let colStride = cellW + GridLayout.spacing
        let scrollMinY = GridScrollOffset.contentMinY

        let minRow = max(0, Int(floor((rect.minY - scrollMinY - GridLayout.padding - GridLayout.cellHeight) / rowStride)))
        let maxRow = min((itemCount - 1) / columns, Int(floor((rect.maxY - scrollMinY - GridLayout.padding) / rowStride)))
        guard minRow <= maxRow else { return result }

        let minCol = max(0, Int(floor((rect.minX - GridLayout.padding - cellW) / colStride)))
        let maxCol = min(columns - 1, Int(floor((rect.maxX - GridLayout.padding) / colStride)))
        guard minCol <= maxCol else { return result }

        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let index = row * columns + col
                guard index < itemCount else { continue }
                let frame = GridLayout.frame(
                    forIndex: index,
                    columns: columns,
                    viewportWidth: viewportWidth,
                    scrollMinY: scrollMinY
                )
                if rect.intersects(frame) {
                    result.insert(folderContents[index].url)
                }
            }
        }
        return result
    }
}

extension View {
    func rubberBandSelection(
        selectedItemURLs: Binding<Set<URL>>,
        activeItemURL: Binding<URL?>,
        folderContents: [FileItem],
        columns: Int,
        viewportWidth: CGFloat
    ) -> some View {
        modifier(RubberBandSelectionGesture(
            selectedItemURLs: selectedItemURLs,
            activeItemURL: activeItemURL,
            folderContents: folderContents,
            columns: columns,
            viewportWidth: viewportWidth
        ))
    }
}

struct GridItemCell: View {
    let item: FileItem
    let isSelected: Bool
    @Binding var selectedItemURLs: Set<URL>
    @Binding var activeItemURL: URL?
    @Binding var fullScreenImageURL: URL?
    @Binding var currentSortOrder: SortOrder
    let loadFolderAction: (URL) -> Void
    let moveItemAction: (URL) -> Void
    let createNewFolderAction: () -> Void
    let newFolderWithSelectionAction: () -> Void
    let openWithKritaAction: (URL) -> Void
    let openWithLightroomAction: (URL) -> Void
    let renameItemAction: (URL) -> Void
    let showPropertiesAction: (URL) -> Void
    let isBookmarked: Bool
    let toggleBookmarkAction: () -> Void
    let isSingleSelection: Bool
    let performDropAction: (URL) -> Void
    let updateSelectionAnchorAction: (URL) -> Void

    @State private var isTargeted: Bool = false
    
    var body: some View {
        VStack {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.blue)
            } else {
                FileItemView(item: item)
            }
            Text(item.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
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
            updateSelectionAnchorAction(item.url)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GridLayout.cellHeight)
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
            if !selectedItemURLs.isEmpty {
                Button { newFolderWithSelectionAction() } label: {
                    Label("New Folder with Selection (\(selectedItemURLs.count) items)", systemImage: "folder.badge.plus")
                }
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
                Button { openWithLightroomAction(item.url) } label: {
                    Label("Open with Lightroom", systemImage: "camera.aperture")
                }
            }
            Divider()
            Button { renameItemAction(item.url) } label: {
                Label(selectedItemURLs.count > 1 && selectedItemURLs.contains(item.url) ? "Rename \(selectedItemURLs.count) Items..." : "Rename...", systemImage: "pencil.line")
            }
            if !item.isDirectory {
                Divider()
                Button { showPropertiesAction(item.url) } label: {
                    Label("Properties", systemImage: "info.circle")
                }
                .disabled(!isSingleSelection)
            }
        }
        .onDrag {
            if !selectedItemURLs.contains(item.url) {
                selectedItemURLs = [item.url]
                activeItemURL = item.url
            }
            return NSItemProvider(object: item.url as NSURL)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            if item.isDirectory {
                performDropAction(item.url)
                return true
            }
            return false
        }
    }
}




enum GridLayout {
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 16
    static let cellHeight: CGFloat = 110
    static let columnWidthDivisor: CGFloat = 116

    static func columnCount(for viewportWidth: CGFloat) -> Int {
        max(1, Int(viewportWidth / columnWidthDivisor))
    }

    static func cellWidth(viewportWidth: CGFloat, columns: Int) -> CGFloat {
        (viewportWidth - padding * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    static func frame(forIndex index: Int, columns: Int, viewportWidth: CGFloat, scrollMinY: CGFloat) -> CGRect {
        let cellW = cellWidth(viewportWidth: viewportWidth, columns: columns)
        let row = index / columns
        let col = index % columns
        let x = padding + CGFloat(col) * (cellW + spacing)
        let y = scrollMinY + padding + CGFloat(row) * (cellHeight + spacing)
        return CGRect(x: x, y: y, width: cellW, height: cellHeight)
    }
}

enum GridScrollOffset {
    static var contentMinY: CGFloat = 0
}

private struct IsScrollingKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isScrolling: Bool {
        get { self[IsScrollingKey.self] }
        set { self[IsScrollingKey.self] = newValue }
    }
}


enum ActivePane {
    case left
    case right
}

struct ContentView: View {
    @StateObject private var sidebarManager = SidebarManager()
    @State private var isShowingFolderPicker = false
    @State private var sidebarSelection: URL?
    @State private var sidebarSelectionRight: URL?
    @StateObject private var session = BrowserSession()
    @StateObject private var sessionRight = BrowserSession()
    @State private var isSplitViewEnabled = false
    @State private var activePane: ActivePane = .left
    @State private var currentColumnCount: Int = 1

    private var activeSidebarSelectionBinding: Binding<URL?> {
        Binding<URL?>(
            get: {
                if isSplitViewEnabled && activePane == .right {
                    return sidebarSelectionRight
                } else {
                    return sidebarSelection
                }
            },
            set: { newValue in
                if isSplitViewEnabled && activePane == .right {
                    sidebarSelectionRight = newValue
                } else {
                    sidebarSelection = newValue
                }
            }
        )
    }

    private var leftPanel: some View {
        SidebarNavigationView(
            manager: sidebarManager,
            selectedFolderURL: activeSidebarSelectionBinding,
            performDropAction: { destinationURL in
                let urlsToMove = Array(activeSession().selectedItemURLs)
                activeSession().moveFiles(urls: urlsToMove, to: destinationURL)
            }
        )
            .fileImporter(
                isPresented: $isShowingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let rawURL = urls.first {
                        let secureURL = sidebarManager.makeSecureURL(rawURL)
                        if isSplitViewEnabled && activePane == .right {
                            sidebarSelectionRight = secureURL
                            sessionRight.saveBookmark(for: secureURL)
                        } else {
                            sidebarSelection = secureURL
                            session.saveBookmark(for: secureURL)
                        }
                    }
                case .failure(let error):
                    print("Error selecting folder: \(error.localizedDescription)")
                }
            }
    }
    
    

    
    
    private func moveSelectionToOtherPane(direction: ActivePane) {
        guard isSplitViewEnabled else { return }
        
        let sourceSession = (direction == .right) ? session : sessionRight
        let destSession = (direction == .right) ? sessionRight : session
        
        guard let sourceFolder = sourceSession.currentFolderURL,
              let destFolder = destSession.currentFolderURL else { return }
              
        if sourceFolder == destFolder {
            sourceSession.showNotification("Cannot move: Source and destination are the same folder")
            return
        }
        
        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
        
        // Refresh destination panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            destSession.loadFolder(url: destFolder, sidebarManager: self.sidebarManager)
        }
    }

        @State private var eventMonitor: Any?

    private func setupKeyboardMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let shiftPressed = event.modifierFlags.contains(.shift)
                let commandPressed = event.modifierFlags.contains(.command)
                
                // Allow normal typing/navigation in text input fields (e.g. rename textfields)
                if let responder = NSApp.keyWindow?.firstResponder {
                    let responderClassName = String(describing: type(of: responder))
                    if responderClassName.contains("Text") {
                        return event
                    }
                }
                
                if commandPressed, let chars = event.charactersIgnoringModifiers?.lowercased() {
                    if chars == "v" {
                        activeSession().pasteFromClipboard(move: shiftPressed)
                        // Force both panels to refresh
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let leftFolder = session.currentFolderURL {
                                session.loadFolder(url: leftFolder, sidebarManager: sidebarManager)
                            }
                            if isSplitViewEnabled, let rightFolder = sessionRight.currentFolderURL {
                                sessionRight.loadFolder(url: rightFolder, sidebarManager: sidebarManager)
                            }
                        }
                        return nil
                    } else if chars == "c" {
                        activeSession().copySelectedItemToClipboard()
                        return nil
                    }
                }
                let optionPressed = event.modifierFlags.contains(.option)
                if commandPressed && !optionPressed {
                    if shiftPressed {
                        if event.keyCode == 126 { // Up arrow
                            activeSession().navigateToFirst()
                            return nil
                        } else if event.keyCode == 125 { // Down arrow
                            activeSession().navigateToLast()
                            return nil
                        }
                    } else {
                        if event.keyCode == 126 { // Up arrow
                            activeSession().navigateUp()
                            return nil
                        } else if event.keyCode == 123 { // Left arrow
                            if activeSession().fullScreenImageURL == nil {
                                activeSession().goBack()
                                return nil
                            }
                        } else if event.keyCode == 124 { // Right arrow
                            if activeSession().fullScreenImageURL == nil {
                                activeSession().goForward()
                                return nil
                            }
                        }
                    }
                }
                
                if !commandPressed && !optionPressed {
                    switch event.keyCode {
                    case 48: // Tab
                        if isSplitViewEnabled {
                            activePane = (activePane == .left) ? .right : .left
                        }
                        return nil // consume event
                    case 120: // F2 key
                        activeSession().renameSelected()
                        return nil // consume event
                    case 123: // Left arrow
                        activeSession().handleLeftArrow(shift: shiftPressed)
                        return nil // consume event
                    case 124: // Right arrow
                        activeSession().handleRightArrow(shift: shiftPressed)
                        return nil
                    case 125: // Down arrow
                        activeSession().handleDownArrow(shift: shiftPressed)
                        return nil
                    case 126: // Up arrow
                        activeSession().handleUpArrow(shift: shiftPressed)
                        return nil
                    default:
                        if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
                            let char = chars.lowercased()
                            let allowedCharacterSet = CharacterSet.letters.union(.decimalDigits)
                            if char.rangeOfCharacter(from: allowedCharacterSet) != nil {
                                activeSession().jumpToFirstItem(startingWith: char)
                                return nil
                            }
                        }
                        break
                    }
                }
                
                return event
            }
        }
    }

    private func activeSession() -> BrowserSession {
        if isSplitViewEnabled && activePane == .right {
            return sessionRight
        }
        return session
    }

    private func clearApplicationMemory() {
        ThumbnailCache.shared.clear()
        ThumbnailDiskCache.shared.clear()
        ThumbnailLoader.shared.reset()
        session.thumbnailLoader.reset()
        sessionRight.thumbnailLoader.reset()
        session.clearMemory()
        if isSplitViewEnabled {
            sessionRight.clearMemory()
        }
        activeSession().showNotification("🧹 Free memory")
    }

    private var shortcutsGroup: some View {
        Group {
            Button(action: {
                if isSplitViewEnabled {
                    activePane = (activePane == .left) ? .right : .left
                }
            }) { Text("") }
                .keyboardShortcut(.tab, modifiers: [])
                .opacity(0)
                
            
            Button(action: {
                if isSplitViewEnabled {
                    moveSelectionToOtherPane(direction: .right)
                }
            }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .opacity(0)
                
            Button(action: {
                if isSplitViewEnabled {
                    moveSelectionToOtherPane(direction: .left)
                }
            }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .opacity(0)

            Button(action: { activeSession().handleUpArrow(shift: NSEvent.modifierFlags.contains(.shift)) }) { Text("") }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleDownArrow(shift: NSEvent.modifierFlags.contains(.shift)) }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleLeftArrow(shift: NSEvent.modifierFlags.contains(.shift)) }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleRightArrow(shift: NSEvent.modifierFlags.contains(.shift)) }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleEnter() }) { Text("") }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleEnter() }) { Text("") }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                
            Button(action: { activeSession().handleEnter() }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .opacity(0)
                

            Button(action: { activeSession().deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: []) // Backspace
                .opacity(0)
                
            Button(action: { activeSession().deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: [.command]) // Cmd + Backspace
                .opacity(0)
                
            Button(action: { activeSession().deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(.delete, modifiers: []) // Forward Delete
                .opacity(0)
                
            Button(action: { activeSession().deleteSelectedItem() }) { Text("") }
                .keyboardShortcut(.delete, modifiers: [.command]) // Cmd + Forward Delete
                .opacity(0)
                
            Button(action: { activeSession().selectAllItems() }) { Text("") }
                .keyboardShortcut("a", modifiers: [.command])
                .opacity(0)

            Button(action: { activeSession().selectAllItemsAndFolders() }) { Text("") }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .opacity(0)

            Button(action: { activeSession().createNewFolder() }) { Text("") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .opacity(0)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let url = activeSession().activeItemURL ?? activeSession().currentFolderURL {
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundColor(activePane == .left ? .white : .blue)
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
                                activeSession().showCopiedFeedback = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                withAnimation {
                                    activeSession().showCopiedFeedback = false
                                }
                            }
                        }
                        .opacity(activeSession().showCopiedFeedback ? 0.3 : 1.0)
                }
                
                if activeSession().showCopiedFeedback {
                    Text("(Copied to clipboard)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                
                Spacer()
                
                Text("\(activeSession().imageItems.count) images" + (activeSession().otherFileCount > 0 ? " | \(activeSession().otherFileCount) other files" : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                
                Text(activeSession().metadataString)
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
                    
                    if isSplitViewEnabled {
                        HSplitView {
                            PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                                .simultaneousGesture(TapGesture().onEnded { activePane = .left })
                                .overlay(alignment: .top) {
                                    if activePane == .left {
                                        Rectangle()
                                            .fill(Color.blue)
                                            .frame(height: 2)
                                    }
                                }
                            PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelectionRight, session: sessionRight)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                                .simultaneousGesture(TapGesture().onEnded { activePane = .right })
                                .overlay(alignment: .top) {
                                    if activePane == .right {
                                        Rectangle()
                                            .fill(Color.blue)
                                            .frame(height: 2)
                                    }
                                }
                        }
                    } else {
                        PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                
                // Full screen presentation is now handled via .onChange of session.fullScreenImageURL

                
                shortcutsGroup

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if let msg = activeSession().notificationMessage {
                            Text(msg)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.8))
                                .cornerRadius(8)
                                .shadow(radius: 4)
                                .padding(.bottom, 30)
                                .padding(.trailing, 20)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .zIndex(1)
                        }
                    }
                }

            }
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
            .frame(width: mainGeometry.size.width, height: mainGeometry.size.height)
        }
        .preferredColorScheme(.dark)
        .onChange(of: sidebarSelection) { oldURL, newURL in
            if let url = newURL {
                session.loadFolder(url: url, sidebarManager: sidebarManager)
            }
        }
        .onChange(of: sidebarSelectionRight) { oldURL, newURL in
            if let url = newURL {
                sessionRight.loadFolder(url: url, sidebarManager: sidebarManager)
            }
        }
        .onChange(of: session.fullScreenImageURL) { oldURL, newURL in
            if let url = newURL {
                ImmersiveWindowController.shared.show {
                    FullScreenImageView(url: url, onClose: {
                        session.fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        session.navigateFullScreen(direction: direction)
                    })
                }
            } else {
                ImmersiveWindowController.shared.hide()
            }
        }
        .onChange(of: session.activeItemURL) { oldURL, newURL in
            session.updateMetadata(for: newURL)
        }
        .onChange(of: sessionRight.fullScreenImageURL) { oldURL, newURL in
            if let url = newURL {
                ImmersiveWindowController.shared.show {
                    FullScreenImageView(url: url, onClose: {
                        sessionRight.fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        sessionRight.navigateFullScreen(direction: direction)
                    })
                }
            } else {
                if session.fullScreenImageURL == nil {
                    ImmersiveWindowController.shared.hide()
                }
            }
        }
        .onChange(of: sessionRight.activeItemURL) { oldURL, newURL in
            sessionRight.updateMetadata(for: newURL)
        }
        .onOpenURL { url in
            let dir = url.deletingLastPathComponent()
            sidebarSelection = dir
            session.activeItemURL = url
            session.selectedItemURLs = [url]
            session.fullScreenImageURL = url
        }
        .sheet(isPresented: $session.isShowingProperties) {
            if let url = session.propertiesURL {
                PropertiesView(url: url)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    clearApplicationMemory()
                }) {
                    Label("Clear Memory", systemImage: "arrow.clockwise")
                }
                .help("Clear Cache & Free Memory")
                
                Button(action: {
                    withAnimation {
                        isSplitViewEnabled.toggle()
                        if isSplitViewEnabled, let currentURL = session.currentFolderURL {
                            sessionRight.loadFolder(url: currentURL, sidebarManager: sidebarManager)
                        }
                    }
                }) {
                    Label("Split View", systemImage: isSplitViewEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .keyboardShortcut("s", modifiers: [.command])
                
                Button(action: {
                    isShowingFolderPicker = true
                }) {
                    Label("Select Folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
        .onAppear {
            setupKeyboardMonitor()
            // Conectar el sidebarManager a ambas sesiones para que toda navegación
            // (Enter, subir a padre, etc.) registre visitas recientes.
            session.sidebarManager = sidebarManager
            sessionRight.sidebarManager = sidebarManager
            if session.currentFolderURL == nil {
                let initialURL = session.restoreBookmark() ?? FileManager.default.homeDirectoryForCurrentUser
                sidebarSelection = initialURL
            }
            if sessionRight.currentFolderURL == nil {
                let initialURLRight = sessionRight.restoreBookmark() ?? FileManager.default.homeDirectoryForCurrentUser
                sidebarSelectionRight = initialURLRight
            }
        }
    }
    
    }

#Preview {
    ContentView()
}
