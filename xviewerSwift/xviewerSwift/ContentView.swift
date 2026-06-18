//
//  ContentView.swift
//  xviewerSwift
//
//  Created by D13 on 17/06/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
}

struct ContentView: View {
    @State private var isShowingFolderPicker = false
    @State private var currentFolderURL: URL?
    @State private var securityScopedURL: URL?
    @State private var folderContents: [FileItem] = []
    @State private var fullScreenImageURL: URL?

    private var imageItems: [FileItem] {
        folderContents.filter { !$0.isDirectory }
    }

    var body: some View {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                        ForEach(folderContents) { item in
                            if item.isDirectory {
                                VStack {
                                    Image(systemName: "folder.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 50, height: 50)
                                        .foregroundColor(.blue)
                                    Text(item.url.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .onTapGesture {
                                    loadFolder(url: item.url)
                                }
                                .help(item.url.lastPathComponent)
                            } else {
                                if let nsImage = NSImage(contentsOf: item.url) {
                                    VStack {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 80, height: 80)
                                            .clipped()
                                            .cornerRadius(8)
                                        Text(item.url.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .help(item.url.lastPathComponent)
                                    .onTapGesture(count: 2) {
                                        fullScreenImageURL = item.url
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            }
            
            if let url = fullScreenImageURL, let nsImage = NSImage(contentsOf: url) {
                ZStack {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                        .onTapGesture {
                            fullScreenImageURL = nil
                        }
                    
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .onTapGesture {
                            fullScreenImageURL = nil
                        }
                    
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                fullScreenImageURL = nil
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
                    }
                    
                    // Keyboard Shortcuts for Navigation
                    Button(action: { navigateImage(direction: -1) }) { Text("").hidden() }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    
                    Button(action: { navigateImage(direction: 1) }) { Text("").hidden() }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .zIndex(1)
            }
            
            // Global Shortcuts
            Button(action: { navigateUp() }) { Text("").hidden() }
                .keyboardShortcut(.upArrow, modifiers: [.command])
        }
    }
    
    private func navigateImage(direction: Int) {
        guard let currentURL = fullScreenImageURL else { return }
        let images = imageItems
        guard let currentIndex = images.firstIndex(where: { $0.url == currentURL }) else { return }
        
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < images.count {
            fullScreenImageURL = images[newIndex].url
        }
    }
    
    private func navigateUp() {
        guard let current = currentFolderURL, let root = securityScopedURL else { return }
        
        // Prevent navigating above the originally selected folder
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
            }
        } catch {
            print("Error loading directory: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
}
