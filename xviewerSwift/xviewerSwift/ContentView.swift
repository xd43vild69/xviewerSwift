//
//  ContentView.swift
//  xviewerSwift
//
//  Created by D13 on 17/06/26.
//

import SwiftUI
import AppKit
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

    var isImage: Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext)
    }
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
    
    // Cambio 2B: Agregar context para discriminar fullscreen vs thumbnail cache
    private func cacheKey(for url: URL, modificationDate: Date, fileSize: Int64, context: String = "thumbnail") -> String {
        let path = url.standardizedFileURL.path
        let modDate = modificationDate.timeIntervalSince1970
        let compositeString = "\(path)_\(modDate)_\(fileSize)_\(context)"
        return compositeString.sha256Hash()
    }

    func get(for url: URL, modificationDate: Date, fileSize: Int64, context: String = "thumbnail") -> NSImage? {
        let key = cacheKey(for: url, modificationDate: modificationDate, fileSize: fileSize, context: context)
        let fileURL = cacheDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return NSImage(contentsOf: fileURL)
        }
        return nil
    }

    func set(_ image: NSImage, for url: URL, modificationDate: Date, fileSize: Int64, context: String = "thumbnail") {
        let key = cacheKey(for: url, modificationDate: modificationDate, fileSize: fileSize, context: context)
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
        cache.countLimit = 0
        cache.totalCostLimit = 2 * 1024 * 1024 * 1024  // 2 GB — ~20,000 thumbnails
    }

    func get(for url: URL) -> NSImage? {
        return cache.object(forKey: url as NSURL)
    }

    func set(_ image: NSImage, for url: URL) {
        let cost = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 102_400
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

extension ThumbnailCache {
    /// Genera o recupera el thumbnail de un item sin debounce de scroll.
    /// Apto para llamarse desde BrowserSession (preload) o desde FileItemView.
    @discardableResult
    static func load(item: FileItem, using loader: ThumbnailLoader) async -> NSImage? {
        let url = item.url

        if let cached = ThumbnailCache.shared.get(for: url) { return cached }

        let diskImg = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return ThumbnailDiskCache.shared.get(for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
        }.value

        if let img = diskImg {
            ThumbnailCache.shared.set(img, for: url)
            return img
        }

        guard !Task.isCancelled else { return nil }

        do {
            try await loader.wait()
            defer { loader.signal() }
            guard !Task.isCancelled else { return nil }

            if let cached = ThumbnailCache.shared.get(for: url) { return cached }

            if item.isLocal {
                let loadTask = Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard !Task.isCancelled else { return nil }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160,
                        kCGImageSourceShouldCache: true
                    ]
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    guard !Task.isCancelled else { return nil }
                    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }
                let img = await withTaskCancellationHandler { await loadTask.value } onCancel: { loadTask.cancel() }
                guard !Task.isCancelled, let img else { return nil }
                ThumbnailCache.shared.set(img, for: url)
                Task.detached(priority: .background) {
                    ThumbnailDiskCache.shared.set(img, for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
                }
                return img
            } else {
                // Estrategia 1: intentar thumbnail embebido (range read, ~30KB) antes de QL
                let embeddedTask = Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard !Task.isCancelled else { return nil }
                    let options: [CFString: Any] = [
                        // Solo el thumbnail EXIF embebido: sin "...Always" y con "...IfAbsent: false"
                        // CoreGraphics devuelve nil si no hay thumb embebido → evita descargar el archivo completo
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        // Estrategia 4: downscaling adaptativo (80px en remoto vs 160px local) — ahorra 75% bytes
                        kCGImageSourceThumbnailMaxPixelSize: item.isLocal ? 160 : 80,
                        kCGImageSourceShouldCache: false  // remoto: no inflar memoria; ya cacheamos a disco
                    ]
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    guard !Task.isCancelled else { return nil }
                    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }
                let embedded = await withTaskCancellationHandler { await embeddedTask.value } onCancel: { embeddedTask.cancel() }

                if let img = embedded {
                    ThumbnailCache.shared.set(img, for: url)
                    Task.detached(priority: .background) {
                        ThumbnailDiskCache.shared.set(img, for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
                    }
                    return img
                }

                guard !Task.isCancelled else { return nil }

                // Fallback: sin thumb embebido → QuickLook (con downscaling en remoto)
                // Estrategia 4: solicitar 80x80 en remoto (80% menos bytes que 160x160)
                let pixelSize: CGFloat = item.isLocal ? 160 : 80
                let size = CGSize(width: pixelSize, height: pixelSize)
                let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2.0, representationTypes: .thumbnail)
                guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
                let img = representation.nsImage
                ThumbnailCache.shared.set(img, for: url)
                Task.detached(priority: .background) {
                    ThumbnailDiskCache.shared.set(img, for: url, modificationDate: item.creationDate, fileSize: item.fileSize)
                }
                return img
            }
        } catch { return nil }
    }
}

// MARK: - GIF Animation Support
struct GIFFrame {
    let cgImage: CGImage
    let duration: Double
}

class GIFAnimator {
    static func isGIF(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "gif"
    }

    // Cambio 4: GIF Lazy Evaluation — limitar a primeros 30 frames
    static func extractFrames(from url: URL, maxFrames: Int = 30) -> [GIFFrame]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        let limitedCount = min(frameCount, maxFrames)  // Limitar a maxFrames
        var frames: [GIFFrame] = []

        for i in 0..<limitedCount {
            guard !Task.isCancelled else { return nil }  // Cancelación
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }

            var duration: Double = 0.1 // Default 100ms
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifDict = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
               let delayTime = gifDict[kCGImagePropertyGIFDelayTime as String] as? NSNumber {
                duration = max(0.01, delayTime.doubleValue) // Min 10ms, GIF times are in seconds
            }

            frames.append(GIFFrame(cgImage: cgImage, duration: duration))
        }

        return frames.isEmpty ? nil : frames
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
            if !item.isImage {
                Image(nsImage: NSWorkspace.shared.icon(forFileType: item.url.pathExtension))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
            } else if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Group {
                    if !item.isLocal {
                        // Estrategia 3: icono de tipo de archivo al instante (sin red) mientras carga el thumb real
                        Image(nsImage: NSWorkspace.shared.icon(forFileType: item.url.pathExtension))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .opacity(0.5)
                    } else {
                        Color.gray.opacity(0.3)
                            .frame(width: 80, height: 80)
                    }
                }
                .cornerRadius(8)
                .task(id: TaskID(url: item.url, isScrolling: isScrolling)) {
                    guard !isScrolling else { return }
                    await loadThumbnail()
                }
            }
        }
    }
    
    private func loadThumbnail() async {
        // Check rápido: ¿está en cache ya? (de preload) → mostrar al instante
        if let cached = ThumbnailCache.shared.get(for: item.url) {
            self.thumbnail = cached
            return
        }

        // No está en cache: hacer debounce antes de generar
        let debounceNs: UInt64 = item.isLocal ? 150_000_000 : 300_000_000
        do { try await Task.sleep(nanoseconds: debounceNs) } catch { return }
        guard !Task.isCancelled else { return }

        if let img = await ThumbnailCache.load(item: item, using: thumbnailLoader) {
            self.thumbnail = img
        } else if !item.isLocal && !Task.isCancelled {
            // Fallback remoto: icono genérico del sistema (solo si no fue cancelado)
            let icon = NSWorkspace.shared.icon(forFileType: item.url.pathExtension)
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
    @State private var gifFrames: [GIFFrame]?
    @State private var currentFrameIndex: Int = 0
    @State private var animationTimer: Timer?
    @State private var isInverted = false
    @State private var isBlackAndWhite = false
    @State private var isFlippedHorizontal = false
    @StateObject private var zoomState = ZoomState()
    @State private var showUI: Bool = true
    @State private var notificationMessage: String? = nil
    @State private var backgroundColorIndex: Int = 0

    private let backgroundColors: [Color] = [
        Color.black,           // 100% black
        Color(white: 0.25),    // 75% black
        Color(white: 0.5),     // 50% gray
        Color(white: 0.75),    // 25% black
        Color.white,           // 100% white
    ]
    
    var body: some View {
        ZStack {
            backgroundColors[backgroundColorIndex]
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            
            if let frames = gifFrames, !frames.isEmpty {
                // Animated GIF
                let nsImage = NSImage(cgImage: frames[currentFrameIndex].cgImage, size: .zero)
                let currentFrame = Image(nsImage: nsImage)
                Group {
                    if isInverted && isBlackAndWhite {
                        currentFrame
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                            .grayscale(1.0)
                    } else if isInverted {
                        currentFrame
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                    } else if isBlackAndWhite {
                        currentFrame
                            .resizable()
                            .scaledToFit()
                            .grayscale(1.0)
                    } else {
                        currentFrame
                            .resizable()
                            .scaledToFit()
                    }
                }
            } else if let image = nsImage {
                // Static image
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
                                // Cambio 3: Reducir zoom máximo a 3x (downsampling causa pixelación visible a 5x)
                                } else if zoomState.totalZoom > 3.0 {
                                    withAnimation(.spring()) {
                                        zoomState.totalZoom = 3.0
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

            Button(action: { cycleBackgroundColor() }) { Text("") }
                .keyboardShortcut("1", modifiers: [.command])
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
            loadImage(from: url)
        }
        .onChange(of: url) { oldURL, newURL in
            stopGIFAnimation()
            nsImage = nil
            gifFrames = nil
            currentFrameIndex = 0
            zoomState.reset()
            loadImage(from: newURL)
        }
        .onDisappear {
            stopGIFAnimation()
        }
    }

    private func stopGIFAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startGIFAnimation(_ frames: [GIFFrame]) {
        stopGIFAnimation()
        guard !frames.isEmpty else { return }

        var frameIndex = 0
        var accumulatedTime = 0.0

        func scheduleNextFrame() {
            let currentDuration = frames[frameIndex].duration
            let nextFrameTime = currentDuration

            animationTimer = Timer.scheduledTimer(withTimeInterval: nextFrameTime, repeats: false) { _ in
                DispatchQueue.main.async {
                    frameIndex = (frameIndex + 1) % frames.count
                    self.currentFrameIndex = frameIndex
                    scheduleNextFrame()
                }
            }
        }

        scheduleNextFrame()
    }

    private func loadImage(from url: URL) {
        // Cambio 1: Security-scoped resource access (para SMB y archivos sandbox)
        let isAccessed = url.startAccessingSecurityScopedResource()
        defer { if isAccessed { url.stopAccessingSecurityScopedResource() } }

        DispatchQueue.global(qos: .userInteractive).async {
            if GIFAnimator.isGIF(url), let frames = GIFAnimator.extractFrames(from: url) {
                DispatchQueue.main.async {
                    self.gifFrames = frames
                    self.currentFrameIndex = 0
                    self.startGIFAnimation(frames)
                }
            } else {
                // Cambio 5: Estrategia de carga para remoto vs local
                let isSMB = url.path.lowercased().contains("/volumes/") &&
                            (url.path.lowercased().contains("smb") || url.path.lowercased().contains("cifs"))

                var loadedImage: NSImage? = nil

                if isSMB {
                    // Estrategia SMB: primero thumb EXIF (rápido, ~30KB), luego downsampling
                    if let embeddedThumb = self.extractEmbeddedThumbnail(imageAt: url) {
                        loadedImage = embeddedThumb
                    } else {
                        // Fallback: downsampling si no hay thumb embebido
                        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
                        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                        loadedImage = self.downsample(imageAt: url, to: screenSize, scale: scale)
                    }
                } else {
                    // Estrategia Local: downsampling directo (mejor calidad que thumb EXIF)
                    let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
                    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                    loadedImage = self.downsample(imageAt: url, to: screenSize, scale: scale)
                }

                // Fallback final: si todo falla, cargar imagen completa (raro)
                if loadedImage == nil {
                    loadedImage = NSImage(contentsOf: url)
                }

                if let image = loadedImage {
                    DispatchQueue.main.async {
                        self.nsImage = image
                    }
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

    private func cycleBackgroundColor() {
        backgroundColorIndex = (backgroundColorIndex + 1) % backgroundColors.count
        let colorNames = ["Black", "75% Black", "Gray", "25% Black", "White"]
        showNotification("🎨 \(colorNames[backgroundColorIndex])")
    }

    // Cambio 5: Extraer thumbnail EXIF embebido para SMB (fallback rápido)
    private func extractEmbeddedThumbnail(imageAt url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,  // Solo thumb embebido, sin decodificar
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSZeroSize)
    }

    // Cambio 2A: Downsampling adaptativo para prevenir OOM (93% reducción de RAM)
    private func downsample(imageAt url: URL, to pointSize: CGSize, scale: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(pointSize.width, pointSize.height) * scale,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSZeroSize)
    }
}



// MARK: - Compare Mode

struct CompareImagePanel: View {
    let url: URL
    let isInverted: Bool
    let isBlackAndWhite: Bool
    let isFlippedHorizontal: Bool

    @State private var nsImage: NSImage?
    @State private var gifFrames: [GIFFrame]?
    @State private var currentFrameIndex: Int = 0
    @State private var animationTimer: Timer?

    var body: some View {
        ZStack {
            Color.black
            imageContent
            VStack {
                Spacer()
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 8)
            }
        }
        .onAppear { loadImage(from: url) }
        .onDisappear { stopGIFAnimation() }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let frames = gifFrames, !frames.isEmpty {
            let frame = Image(nsImage: NSImage(cgImage: frames[currentFrameIndex].cgImage, size: .zero))
            applyEffects(to: frame)
        } else if let image = nsImage {
            applyEffects(to: Image(nsImage: image))
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder
    private func applyEffects(to image: Image) -> some View {
        let base = image.resizable().scaledToFit()
            .scaleEffect(x: isFlippedHorizontal ? -1 : 1, y: 1)
        if isInverted && isBlackAndWhite {
            base.colorInvert().grayscale(1.0)
        } else if isInverted {
            base.colorInvert()
        } else if isBlackAndWhite {
            base.grayscale(1.0)
        } else {
            base
        }
    }

    private func loadImage(from url: URL) {
        DispatchQueue.global(qos: .userInteractive).async {
            if GIFAnimator.isGIF(url), let frames = GIFAnimator.extractFrames(from: url) {
                DispatchQueue.main.async {
                    self.gifFrames = frames
                    self.currentFrameIndex = 0
                    self.startGIFAnimation(frames)
                }
            } else if let img = NSImage(contentsOf: url) {
                DispatchQueue.main.async { self.nsImage = img }
            }
        }
    }

    private func stopGIFAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startGIFAnimation(_ frames: [GIFFrame]) {
        stopGIFAnimation()
        guard !frames.isEmpty else { return }
        var frameIndex = 0
        func scheduleNext() {
            animationTimer = Timer.scheduledTimer(withTimeInterval: frames[frameIndex].duration, repeats: false) { _ in
                DispatchQueue.main.async {
                    frameIndex = (frameIndex + 1) % frames.count
                    self.currentFrameIndex = frameIndex
                    scheduleNext()
                }
            }
        }
        scheduleNext()
    }
}

struct CompareView: View {
    let urlA: URL
    let urlB: URL
    let onClose: () -> Void

    @State private var isInverted = false
    @State private var isBlackAndWhite = false
    @State private var isFlippedHorizontal = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
                CompareImagePanel(url: urlA,
                                  isInverted: isInverted,
                                  isBlackAndWhite: isBlackAndWhite,
                                  isFlippedHorizontal: isFlippedHorizontal)
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 2)
                CompareImagePanel(url: urlB,
                                  isInverted: isInverted,
                                  isBlackAndWhite: isBlackAndWhite,
                                  isFlippedHorizontal: isFlippedHorizontal)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle).foregroundColor(.white).padding()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Spacer()
            }
            Button { isInverted.toggle() } label: { Text("") }
                .keyboardShortcut("i", modifiers: [.command]).opacity(0)
            Button { isBlackAndWhite.toggle() } label: { Text("") }
                .keyboardShortcut("b", modifiers: [.command]).opacity(0)
            Button { isFlippedHorizontal.toggle() } label: { Text("") }
                .keyboardShortcut("h", modifiers: [.command]).opacity(0)
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
    let isActive: Bool
    let canCompare: Bool
    let compareAction: () -> Void

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
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ActiveItemFrameKey.self,
                    value: isActive ? geo.frame(in: .global) : .zero
                )
            }
        )
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
            if item.isDirectory {
                activeItemURL = item.url
                selectedItemURLs = [item.url]
                loadFolderAction(item.url)
            } else if item.isImage {
                activeItemURL = item.url
                selectedItemURLs = [item.url]
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
            if canCompare {
                Divider()
                Button { compareAction() } label: {
                    Label("Compare", systemImage: "square.split.2x1")
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

class ContextMenuHandler: NSObject {
    var session: BrowserSession?
    var sidebarManager: SidebarManager?
    var crossPaneAction: (() -> Void)?

    @objc func sortByName() {
        DispatchQueue.main.async {
            self.session?.currentSortOrder = .name
        }
    }
    @objc func sortByDate() {
        DispatchQueue.main.async {
            self.session?.currentSortOrder = .date
        }
    }
    @objc func sortBySize() {
        DispatchQueue.main.async {
            self.session?.currentSortOrder = .size
        }
    }
    @objc func createNewFolder() {
        DispatchQueue.main.async {
            self.session?.createNewFolder()
        }
    }
    @objc func newFolderWithSelection() {
        DispatchQueue.main.async {
            self.session?.createNewFolderWithSelection()
        }
    }
    @objc func renameSelected() {
        DispatchQueue.main.async {
            self.session?.renameSelected()
        }
    }
    @objc func deleteSelected() {
        DispatchQueue.main.async {
            self.session?.deleteSelectedItem()
        }
    }
    @objc func selectAll() {
        DispatchQueue.main.async {
            self.session?.selectAllItems()
        }
    }
    @objc func selectAllWithFolders() {
        DispatchQueue.main.async {
            self.session?.selectAllItemsAndFolders()
        }
    }
    @objc func openWithKrita() {
        DispatchQueue.main.async {
            guard let url = self.session?.activeItemURL else { return }
            self.session?.openWithKrita(url)
        }
    }
    @objc func openWithLightroom() {
        DispatchQueue.main.async {
            guard let url = self.session?.activeItemURL else { return }
            self.session?.openWithLightroom(url)
        }
    }
    @objc func compare() {
        DispatchQueue.main.async {
            guard let session = self.session else { return }
            let urls = Array(session.selectedItemURLs)
                .filter { url in session.folderContents.first(where: { $0.url == url })?.isDirectory == false }
            if urls.count == 2 {
                session.compareImageURLs = urls
            }
        }
    }
    @objc func compareCrossPane() {
        DispatchQueue.main.async { self.crossPaneAction?() }
    }
    @objc func undoLastAction() {
        DispatchQueue.main.async {
            self.session?.undoLastAction()
        }
    }
}


struct ActiveItemFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

enum ActivePane {
    case left
    case right
}

struct ContentView: View {
    @StateObject private var sidebarManager = SidebarManager()
    @State private var isShowingFolderPicker = false
    @State private var isShowingSettings = false
    @State private var sidebarSelection: URL?
    @State private var sidebarSelectionRight: URL?
    @StateObject private var session = BrowserSession()
    @StateObject private var sessionRight = BrowserSession()
    @State private var isSplitViewEnabled = false
    @State private var activePane: ActivePane = .left
    @State private var activeItemGlobalFrame: CGRect = .zero
    @State private var crossPaneCompareURLs: [URL]? = nil

    enum FocusField: Hashable {
        case filterInputLeft
        case filterInputRight
    }
    @FocusState private var focusedField: FocusField?

    private var crossPaneSelectedImages: [URL]? {
        guard isSplitViewEnabled else { return nil }
        let leftImgs = session.selectedItemURLs.filter { url in
            if let found = session.folderContents.first(where: { $0.url == url }) {
                return !found.isDirectory && found.isImage
            }
            return false
        }
        let rightImgs = sessionRight.selectedItemURLs.filter { url in
            if let found = sessionRight.folderContents.first(where: { $0.url == url }) {
                return !found.isDirectory && found.isImage
            }
            return false
        }
        guard leftImgs.count == 1, rightImgs.count == 1 else { return nil }
        return [leftImgs.first!, rightImgs.first!]
    }

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
                
                // Do not intercept grid navigation or file operations if an immersive view is active
                if self.session.fullScreenImageURL != nil || self.sessionRight.fullScreenImageURL != nil || self.session.compareImageURLs != nil || self.sessionRight.compareImageURLs != nil {
                    return event
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
                    } else if chars == "/" {
                        showContextMenu()
                        return nil
                    } else if chars == "z" {
                        activeSession().undoLastAction()
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
                        } else if event.keyCode == 33 { // [ bracket
                            activeSession().navigateToFirst()
                            return nil
                        } else if event.keyCode == 30 { // ] bracket
                            activeSession().navigateToLast()
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
                    case 99: // F3 key
                        let activeSess = activeSession()
                        if !activeSess.filterText.isEmpty {
                            activeSess.filterText = ""
                            activeSess.isFilterBarPresented = false
                            focusedField = nil
                        } else {
                            activeSess.isFilterBarPresented.toggle()
                            if activeSess.isFilterBarPresented {
                                focusedField = (activePane == .left) ? .filterInputLeft : .filterInputRight
                            } else {
                                focusedField = nil
                            }
                        }
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
        activeSession().showNotification("🧹 Cleaned: Thumbnails • History • Undo • Cache")
    }

    private func showContextMenu() {
        let session = activeSession()
        let handler = ContextMenuHandler()
        handler.session = session
        handler.sidebarManager = sidebarManager
        handler.crossPaneAction = {
            if let urls = self.crossPaneSelectedImages {
                self.crossPaneCompareURLs = urls
            }
        }

        let menu = NSMenu()

        // Sort options
        let sortMenu = NSMenu()
        sortMenu.addItem(withTitle: "Name", action: #selector(ContextMenuHandler.sortByName), keyEquivalent: "").target = handler
        sortMenu.addItem(withTitle: "Date", action: #selector(ContextMenuHandler.sortByDate), keyEquivalent: "").target = handler
        sortMenu.addItem(withTitle: "Size", action: #selector(ContextMenuHandler.sortBySize), keyEquivalent: "").target = handler

        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(NSMenuItem.separator())

        // Undo option (only if available)
        if session.canUndo, let lastAction = session.undoHistory.last {
            let undoItem = NSMenuItem(
                title: "Undo: \(lastAction.actionDescription)",
                action: #selector(ContextMenuHandler.undoLastAction),
                keyEquivalent: ""
            )
            undoItem.target = handler
            menu.addItem(undoItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Basic options
        menu.addItem(withTitle: "New Folder", action: #selector(ContextMenuHandler.createNewFolder), keyEquivalent: "").target = handler

        if !session.selectedItemURLs.isEmpty {
            menu.addItem(withTitle: "New Folder with Selection (\(session.selectedItemURLs.count) items)", action: #selector(ContextMenuHandler.newFolderWithSelection), keyEquivalent: "").target = handler
        }

        // Check if there's an active item
        if let activeItem = session.activeItemURL,
           let item = session.folderContents.first(where: { $0.url == activeItem }) {

            menu.addItem(NSMenuItem.separator())

            // Folder-specific options
            if item.isDirectory {
                menu.addItem(withTitle: "Add to Bookmarks", action: nil, keyEquivalent: "")
            }

            // Image-specific options
            if !item.isDirectory {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "Open with Krita", action: #selector(ContextMenuHandler.openWithKrita), keyEquivalent: "").target = handler
                menu.addItem(withTitle: "Open with Lightroom", action: #selector(ContextMenuHandler.openWithLightroom), keyEquivalent: "").target = handler
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Rename", action: #selector(ContextMenuHandler.renameSelected), keyEquivalent: "").target = handler
        menu.addItem(withTitle: "Delete", action: #selector(ContextMenuHandler.deleteSelected), keyEquivalent: "").target = handler

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Select All Items", action: #selector(ContextMenuHandler.selectAll), keyEquivalent: "").target = handler
        menu.addItem(withTitle: "Select All (Items & Folders)", action: #selector(ContextMenuHandler.selectAllWithFolders), keyEquivalent: "").target = handler

        if session.selectedItemURLs.count == 2 &&
           session.selectedItemURLs.allSatisfy({ url in
               session.folderContents.first(where: { $0.url == url })?.isDirectory == false
           }) {
            menu.addItem(NSMenuItem.separator())
            let compareItem = NSMenuItem(title: "Compare", action: #selector(ContextMenuHandler.compare), keyEquivalent: "")
            compareItem.target = handler
            menu.addItem(compareItem)
        }

        if crossPaneSelectedImages != nil {
            menu.addItem(NSMenuItem.separator())
            let crossItem = NSMenuItem(title: "Compare (Left vs Right)", action: #selector(ContextMenuHandler.compareCrossPane), keyEquivalent: "")
            crossItem.target = handler
            menu.addItem(crossItem)
        }

        // Convert SwiftUI global frame to screen coordinates for NSMenu positioning
        // SwiftUI global space has origin at top-left of window content; NSScreen at bottom-left
        let screenPoint: NSPoint
        if let window = NSApp.keyWindow, activeItemGlobalFrame != .zero {
            let contentHeight = window.contentView?.bounds.height ?? 0
            let windowOrigin = window.frame.origin
            // SwiftUI Y increases downward; NSWindow Y increases upward — flip
            let nsWindowY = contentHeight - activeItemGlobalFrame.maxY
            screenPoint = NSPoint(
                x: windowOrigin.x + activeItemGlobalFrame.midX,
                y: windowOrigin.y + nsWindowY
            )
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: screenPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) ?? NSEvent()

        if let view = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private func updateWindowTitle() {
        let folderName = activeSession().currentFolderURL?.lastPathComponent ?? "xViewer"
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.title = folderName
            }
        }
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

    private var notificationOverlay: some View {
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

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()

            if activeSession().fileOperation.isActive {
                HStack(spacing: 8) {
                    ProgressView(value: activeSession().fileOperation.progress)
                        .frame(maxWidth: 150)

                    Text("\(activeSession().fileOperation.processedCount)/\(activeSession().fileOperation.totalCount)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 50)

                    Text(activeSession().fileOperation.currentFile)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                HStack {
                    if let url = activeSession().activeItemURL ?? activeSession().currentFolderURL {
                        Text(url.path)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
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

                    Text("\(activeSession().imageItems.count) images" + (activeSession().otherFilesDisplayCount > 0 ? " | \(activeSession().otherFilesDisplayCount) other files" : ""))
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
    }

    @ViewBuilder
    private func browserContent(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: width * 0.1)
            if isSplitViewEnabled {
                HSplitView {
                    PaneBrowserView(
                        sidebarManager: sidebarManager,
                        sidebarSelection: $sidebarSelection,
                        session: session,
                        otherPaneSelectedImageCount: sessionRight.selectedItemURLs.filter { url in
                            if let found = sessionRight.folderContents.first(where: { $0.url == url }) {
                                return !found.isDirectory && found.isImage
                            }
                            return false
                        }.count,
                        crossPaneCompareAction: {
                            if let urls = crossPaneSelectedImages {
                                crossPaneCompareURLs = urls
                            }
                        }
                    )
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded { activePane = .left })
                    .overlay(alignment: .top) {
                        if activePane == .left {
                            Rectangle().fill(Color.blue).frame(height: 2)
                        }
                    }
                    PaneBrowserView(
                        sidebarManager: sidebarManager,
                        sidebarSelection: $sidebarSelectionRight,
                        session: sessionRight,
                        otherPaneSelectedImageCount: session.selectedItemURLs.filter { url in
                            if let found = session.folderContents.first(where: { $0.url == url }) {
                                return !found.isDirectory && found.isImage
                            }
                            return false
                        }.count,
                        crossPaneCompareAction: {
                            if let urls = crossPaneSelectedImages {
                                crossPaneCompareURLs = urls
                            }
                        }
                    )
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded { activePane = .right })
                    .overlay(alignment: .top) {
                        if activePane == .right {
                            Rectangle().fill(Color.blue).frame(height: 2)
                        }
                    }
                }
            } else {
                PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var mainLayout: some View {
        GeometryReader { mainGeometry in
            ZStack {
                browserContent(width: mainGeometry.size.width)
                shortcutsGroup
                notificationOverlay
            }
            .safeAreaInset(edge: .bottom) { statusBar }
            .frame(width: mainGeometry.size.width, height: mainGeometry.size.height)
        }
    }

    private var layoutWithSessionObservers: some View {
        mainLayout
            .onChange(of: sidebarSelection) { _, newURL in
                if let url = newURL { session.loadFolder(url: url, sidebarManager: sidebarManager) }
            }
            .onChange(of: sidebarSelectionRight) { _, newURL in
                if let url = newURL { sessionRight.loadFolder(url: url, sidebarManager: sidebarManager) }
            }
            .onChange(of: session.fullScreenImageURL) { _, newURL in
                if let url = newURL {
                    ImmersiveWindowController.shared.show {
                        FullScreenImageView(url: url, onClose: { session.fullScreenImageURL = nil },
                                            navigateImage: { session.navigateFullScreen(direction: $0) })
                    }
                } else { ImmersiveWindowController.shared.hide() }
            }
            .onChange(of: session.activeItemURL) { _, newURL in
                if newURL != nil {
                    activePane = .left
                }
                session.updateMetadata(for: newURL)
            }
            .onChange(of: sessionRight.fullScreenImageURL) { _, newURL in
                if let url = newURL {
                    ImmersiveWindowController.shared.show {
                        FullScreenImageView(url: url, onClose: { sessionRight.fullScreenImageURL = nil },
                                            navigateImage: { sessionRight.navigateFullScreen(direction: $0) })
                    }
                } else if session.fullScreenImageURL == nil { ImmersiveWindowController.shared.hide() }
            }
            .onChange(of: sessionRight.activeItemURL) { _, newURL in
                if newURL != nil {
                    activePane = .right
                }
                sessionRight.updateMetadata(for: newURL)
            }
            .onChange(of: session.compareImageURLs) { _, newURLs in
                if let urls = newURLs, urls.count == 2 {
                    ImmersiveWindowController.shared.show {
                        CompareView(urlA: urls[0], urlB: urls[1], onClose: { session.compareImageURLs = nil })
                    }
                } else if newURLs == nil && session.fullScreenImageURL == nil {
                    ImmersiveWindowController.shared.hide()
                }
            }
            .onChange(of: sessionRight.compareImageURLs) { _, newURLs in
                if let urls = newURLs, urls.count == 2 {
                    ImmersiveWindowController.shared.show {
                        CompareView(urlA: urls[0], urlB: urls[1], onClose: { sessionRight.compareImageURLs = nil })
                    }
                } else if newURLs == nil && sessionRight.fullScreenImageURL == nil {
                    ImmersiveWindowController.shared.hide()
                }
            }
            .onChange(of: crossPaneCompareURLs) { _, newURLs in
                if let urls = newURLs, urls.count == 2 {
                    ImmersiveWindowController.shared.show {
                        CompareView(urlA: urls[0], urlB: urls[1], onClose: { crossPaneCompareURLs = nil })
                    }
                } else if newURLs == nil
                    && session.compareImageURLs == nil
                    && sessionRight.compareImageURLs == nil
                    && session.fullScreenImageURL == nil
                    && sessionRight.fullScreenImageURL == nil {
                    ImmersiveWindowController.shared.hide()
                }
            }
            .onChange(of: session.undoHistory.count) { oldCount, newCount in
                // Only reload when undo happens (count DECREASES), not on new actions
                if newCount < oldCount && isSplitViewEnabled {
                    if let rightFolder = sessionRight.currentFolderURL {
                        sessionRight.loadFolder(url: rightFolder, sidebarManager: sidebarManager)
                    }
                }
            }
            .onChange(of: sessionRight.undoHistory.count) { oldCount, newCount in
                // Only reload when undo happens (count DECREASES), not on new actions
                if newCount < oldCount && isSplitViewEnabled {
                    if let leftFolder = session.currentFolderURL {
                        session.loadFolder(url: leftFolder, sidebarManager: sidebarManager)
                    }
                }
            }
    }

    var body: some View {
        layoutWithSessionObservers
            .onPreferenceChange(ActiveItemFrameKey.self) { frame in
                if frame != .zero { activeItemGlobalFrame = frame }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                sidebarSelection = url.deletingLastPathComponent()
                session.activeItemURL = url
                session.selectedItemURLs = [url]
                session.fullScreenImageURL = url
            }
            .sheet(isPresented: $session.isShowingProperties) {
                if let url = session.propertiesURL { PropertiesView(url: url) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if session.isFilterBarPresented || !session.filterText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                            TextField(isSplitViewEnabled ? "Filter Left..." : "Filter...", text: $session.filterText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .frame(width: 120)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .focused($focusedField, equals: .filterInputLeft)
                                .onSubmit {
                                    focusedField = nil
                                }
                                .onExitCommand {
                                    session.filterText = ""
                                    session.isFilterBarPresented = false
                                    focusedField = nil
                                }
                            if !session.filterText.isEmpty {
                                Button(action: {
                                    session.filterText = ""
                                    session.isFilterBarPresented = false
                                    focusedField = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    if isSplitViewEnabled && (sessionRight.isFilterBarPresented || !sessionRight.filterText.isEmpty) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                            TextField("Filter Right...", text: $sessionRight.filterText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .frame(width: 120)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .focused($focusedField, equals: .filterInputRight)
                                .onSubmit {
                                    focusedField = nil
                                }
                                .onExitCommand {
                                    sessionRight.filterText = ""
                                    sessionRight.isFilterBarPresented = false
                                    focusedField = nil
                                }
                            if !sessionRight.filterText.isEmpty {
                                Button(action: {
                                    sessionRight.filterText = ""
                                    sessionRight.isFilterBarPresented = false
                                    focusedField = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    Button { clearApplicationMemory() } label: {
                        Label("Clear Memory", systemImage: "arrow.clockwise")
                    }
                    .help("Clear Cache & Free Memory")
                    Button {
                        let newValue = !session.showAllFiles
                        session.showAllFiles = newValue
                        if let url = session.currentFolderURL {
                            session.loadFolder(url: url, sidebarManager: sidebarManager)
                        }
                        sessionRight.showAllFiles = newValue
                        if isSplitViewEnabled, let url = sessionRight.currentFolderURL {
                            sessionRight.loadFolder(url: url, sidebarManager: sidebarManager)
                        }
                    } label: {
                        Label(session.showAllFiles ? "Hide Other Files" : "Show All Files", systemImage: session.showAllFiles ? "eye" : "eye.slash")
                    }
                    .help(session.showAllFiles ? "Show only images" : "Show all file types")
                    Button {
                        withAnimation {
                            isSplitViewEnabled.toggle()
                            if isSplitViewEnabled, let url = session.currentFolderURL {
                                sessionRight.loadFolder(url: url, sidebarManager: sidebarManager)
                            }
                        }
                    } label: {
                        Label("Split View", systemImage: isSplitViewEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    Button { isShowingFolderPicker = true } label: {
                        Label("Select Folder", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                    Button { isShowingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onAppear {
                setupKeyboardMonitor()
                session.sidebarManager = sidebarManager
                sessionRight.sidebarManager = sidebarManager
                if session.currentFolderURL == nil {
                    sidebarSelection = session.restoreBookmark() ?? FileManager.default.homeDirectoryForCurrentUser
                }
                if sessionRight.currentFolderURL == nil {
                    sidebarSelectionRight = sessionRight.restoreBookmark() ?? FileManager.default.homeDirectoryForCurrentUser
                }
                updateWindowTitle()
            }

            .onChange(of: activeSession().currentFolderURL) { _, _ in updateWindowTitle() }
    }
    
    }

#Preview {
    ContentView()
}
