//
//  ContentView.swift
//  xviewerSwift
//
//  Created by D13 on 17/06/26.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
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
                    .onAppear {
                        loadThumbnail()
                    }
            }
        }
    }
    
    private func loadThumbnail() {
        let size = CGSize(width: 160, height: 160)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )
        
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            if let nsImage = representation?.nsImage {
                DispatchQueue.main.async {
                    self.thumbnail = nsImage
                }
            } else {
                DispatchQueue.global(qos: .background).async {
                    if let img = NSImage(contentsOf: url) {
                        DispatchQueue.main.async {
                            self.thumbnail = img
                        }
                    }
                }
            }
        }
    }
}

struct FullScreenImageView: View {
    let url: URL
    let onClose: () -> Void
    let navigateImage: (Int) -> Void
    
    @State private var nsImage: NSImage?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            
            if let image = nsImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
                    .onTapGesture { onClose() }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onClose() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Spacer()
            }
            
            Button(action: { navigateImage(-1) }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
            
            Button(action: { navigateImage(1) }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
        }
        .zIndex(1)
        .onAppear { loadImage(from: url) }
        .onChange(of: url) { newURL in
            nsImage = nil
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

struct ContentView: View {
    @State private var isShowingFolderPicker = false
    @State private var currentFolderURL: URL?
    @State private var securityScopedURL: URL?
    @State private var folderContents: [FileItem] = []
    @State private var fullScreenImageURL: URL?
    @State private var selectedItemURL: URL?
    @State private var currentColumnCount: Int = 1

    private var imageItems: [FileItem] {
        folderContents.filter { !$0.isDirectory }
    }

    var body: some View {
        GeometryReader { mainGeometry in
            ZStack {
                HStack(spacing: 0) {
                    // Left Panel
                    VStack {
                        Button("Select Folder") {
                            isShowingFolderPicker = true
                        }
                        .padding()
                        
                        if let url = currentFolderURL {
                            Text("Selected: \(url.lastPathComponent)")
                                .font(.caption)
                                .padding(.horizontal)
                        }
                        Spacer()
                    }
                    .frame(width: mainGeometry.size.width * 0.1)
                    .frame(maxHeight: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .fileImporter(
                        isPresented: $isShowingFolderPicker,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        switch result {
                        case .success(let urls):
                            if let url = urls.first {
                                securityScopedURL?.stopAccessingSecurityScopedResource()
                                if url.startAccessingSecurityScopedResource() {
                                    securityScopedURL = url
                                }
                                loadFolder(url: url)
                            }
                        case .failure(let error):
                            print("Error selecting folder: \(error.localizedDescription)")
                        }
                    }
                    
                    // Right Panel
                    GeometryReader { geometry in
                        let columns = max(1, Int(geometry.size.width / 116))
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                                ForEach(folderContents) { item in
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
                                            .fill(selectedItemURL == item.url ? Color.blue.opacity(0.2) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedItemURL == item.url ? Color.blue : Color.clear, lineWidth: 2)
                                    )
                                    .help(item.url.lastPathComponent)
                                    .onTapGesture(count: 2) {
                                        selectedItemURL = item.url
                                        if item.isDirectory {
                                            loadFolder(url: item.url)
                                        } else {
                                            fullScreenImageURL = item.url
                                        }
                                    }
                                    .onTapGesture(count: 1) {
                                        selectedItemURL = item.url
                                    }
                                }
                            }
                            .padding()
                        }
                        .onChange(of: columns) { newValue in
                            currentColumnCount = newValue
                        }
                        .onAppear {
                            currentColumnCount = columns
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                if let url = fullScreenImageURL {
                    FullScreenImageView(url: url, onClose: {
                        fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        navigateFullScreen(direction: direction)
                    })
                }
                
                // Global Shortcuts
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
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .opacity(0)
            }
            .frame(width: mainGeometry.size.width, height: mainGeometry.size.height)
        }
        .preferredColorScheme(.dark)
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
        guard let currentSelected = selectedItemURL, let currentIndex = folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            selectedItemURL = folderContents.first?.url
            return
        }
        let newIndex = currentIndex + (direction * currentColumnCount)
        if newIndex >= 0 && newIndex < folderContents.count {
            selectedItemURL = folderContents[newIndex].url
        } else if newIndex < 0 {
            selectedItemURL = folderContents.first?.url
        } else if newIndex >= folderContents.count {
            selectedItemURL = folderContents.last?.url
        }
    }
    
    private func navigateGrid(direction: Int) {
        guard !folderContents.isEmpty else { return }
        guard let currentSelected = selectedItemURL, let currentIndex = folderContents.firstIndex(where: { $0.url == currentSelected }) else {
            selectedItemURL = folderContents.first?.url
            return
        }
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < folderContents.count {
            selectedItemURL = folderContents[newIndex].url
        }
    }
    
    private func navigateFullScreen(direction: Int) {
        guard let currentURL = fullScreenImageURL else { return }
        let images = imageItems
        guard let currentIndex = images.firstIndex(where: { $0.url == currentURL }) else { return }
        
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < images.count {
            fullScreenImageURL = images[newIndex].url
        }
    }
    
    private func handleEnter() {
        guard fullScreenImageURL == nil else { return }
        guard let selected = selectedItemURL else { return }
        
        if let item = folderContents.first(where: { $0.url == selected }) {
            if item.isDirectory {
                loadFolder(url: item.url)
            } else {
                fullScreenImageURL = item.url
            }
        }
    }
    
    private func navigateUp() {
        guard let current = currentFolderURL, let root = securityScopedURL else { return }
        
        if current.standardizedFileURL.path != root.standardizedFileURL.path {
            let parentURL = current.deletingLastPathComponent()
            loadFolder(url: parentURL)
        }
    }
    
    private func loadFolder(url: URL) {
        currentFolderURL = url
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            
            var items: [FileItem] = []
            for fileURL in fileURLs {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues.isDirectory ?? false
                
                if !isDirectory {
                    let ext = fileURL.pathExtension.lowercased()
                    let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp"]
                    if imageExtensions.contains(ext) {
                        items.append(FileItem(url: fileURL, isDirectory: false))
                    }
                } else {
                    items.append(FileItem(url: fileURL, isDirectory: true))
                }
            }
            
            items.sort {
                if $0.isDirectory && !$1.isDirectory { return true }
                if !$0.isDirectory && $1.isDirectory { return false }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            
            DispatchQueue.main.async {
                self.folderContents = items
                self.selectedItemURL = items.first?.url
            }
        } catch {
            print("Error loading directory: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
}
