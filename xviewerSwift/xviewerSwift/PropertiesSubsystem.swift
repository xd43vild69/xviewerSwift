import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

struct PropertiesView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    @State private var metadataText: String = "Extracting metadata..."
    @State private var showCopiedFeedback = false
    
    @State private var searchText: String = ""
    @State private var currentMatchIndex: Int = 0
    @State private var totalMatches: Int = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Properties")
                    .font(.title2)
                    .fontWeight(.bold)
                // Custom search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onChange(of: searchText) { _ in
                            currentMatchIndex = 0
                        }
                    
                    if totalMatches > 0 {
                        Text("\(currentMatchIndex + 1)/\(totalMatches)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .center)
                        
                        Button(action: {
                            if currentMatchIndex > 0 {
                                currentMatchIndex -= 1
                            } else {
                                currentMatchIndex = totalMatches - 1
                            }
                        }) {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        
                        Button(action: {
                            if currentMatchIndex < totalMatches - 1 {
                                currentMatchIndex += 1
                            } else {
                                currentMatchIndex = 0
                            }
                        }) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            
            Text(url.lastPathComponent)
                .font(.headline)
            
            SearchableTextView(
                text: metadataText,
                searchText: $searchText,
                currentMatchIndex: $currentMatchIndex,
                totalMatches: $totalMatches
            )
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            
            HStack {
                if showCopiedFeedback {
                    Text("Copied to clipboard!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button(action: copyToClipboard) {
                    Label("Copy Metadata", systemImage: "doc.on.doc")
                }
                .disabled(metadataText.contains("No se detectaron"))
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .onAppear {
            extractMetadata()
        }
    }
    
    private func extractMetadata() {
        Task.detached(priority: .userInitiated) {
            let isAccessed = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            guard let pngDictionary = extractPNGTextChunks(from: url) else {
                await MainActor.run {
                    self.metadataText = "No se detectaron metadatos de ComfyUI en este asset (No tEXt chunks encontrados)."
                }
                return
            }
            
            var extractedText = ""
            
            if let comfyPrompt = pngDictionary["prompt"] {
                extractedText += "--- PROMPT ---\n\(comfyPrompt)\n\n"
            }
            if let workflow = pngDictionary["workflow"] {
                extractedText += "--- WORKFLOW ---\n\(workflow)\n"
            }
            
            if extractedText.isEmpty {
                extractedText = "No se detectaron metadatos de ComfyUI en este asset (faltan claves 'prompt' o 'workflow')."
            }
            
            let finalText = extractedText
            await MainActor.run {
                self.metadataText = finalText
            }
        }
    }
    
    nonisolated private func extractPNGTextChunks(from url: URL) -> [String: String]? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        
        do {
            let signature = try fileHandle.read(upToCount: 8)
            let expectedSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            guard signature == expectedSignature else { return nil }
            
            var textDict: [String: String] = [:]
            
            while true {
                guard let lengthData = try fileHandle.read(upToCount: 4), lengthData.count == 4 else { break }
                let length = Int(UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                guard let typeData = try fileHandle.read(upToCount: 4), typeData.count == 4 else { break }
                let type = String(data: typeData, encoding: .ascii)
                
                if type == "tEXt" {
                    if let chunkData = try fileHandle.read(upToCount: length) {
                        if let nullIndex = chunkData.firstIndex(of: 0) {
                            let keywordData = chunkData[0..<nullIndex]
                            let textData = chunkData[(nullIndex + 1)...]
                            if let keyword = String(data: keywordData, encoding: .isoLatin1),
                               let text = String(data: textData, encoding: .utf8) {
                                textDict[keyword] = text
                            }
                        }
                    }
                } else if type == "IEND" {
                    break
                } else {
                    try fileHandle.seek(toOffset: try fileHandle.offset() + UInt64(length))
                }
                
                try fileHandle.seek(toOffset: try fileHandle.offset() + 4)
            }
            return textDict.isEmpty ? nil : textDict
        } catch {
            return nil
        }
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(metadataText, forType: .string)
        
        withAnimation {
            showCopiedFeedback = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }
}

struct SearchableTextView: NSViewRepresentable {
    var text: String
    @Binding var searchText: String
    @Binding var currentMatchIndex: Int
    @Binding var totalMatches: Int
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = NSColor.textColor
            textView.backgroundColor = .clear
            textView.textContainerInset = NSSize(width: 10, height: 10)
        }
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
            
            let nsString = textView.string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            
            // Limpiar resaltados anteriores
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            
            if searchText.isEmpty {
                DispatchQueue.main.async {
                    if self.totalMatches != 0 { self.totalMatches = 0 }
                }
                return
            }
            
            var ranges: [NSRange] = []
            var searchRange = fullRange
            
            while searchRange.location < nsString.length {
                let range = nsString.range(of: searchText, options: .caseInsensitive, range: searchRange)
                if range.location != NSNotFound {
                    ranges.append(range)
                    // Resaltado suave para todas las coincidencias
                    textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: range)
                    searchRange.location = range.location + range.length
                    searchRange.length = nsString.length - searchRange.location
                } else {
                    break
                }
            }
            
            DispatchQueue.main.async {
                if self.totalMatches != ranges.count {
                    self.totalMatches = ranges.count
                }
            }
            
            if !ranges.isEmpty {
                let safeIndex = max(0, min(currentMatchIndex, ranges.count - 1))
                let activeRange = ranges[safeIndex]
                
                // Resaltado fuerte para la coincidencia actual
                textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow, forCharacterRange: activeRange)
                textView.scrollRangeToVisible(activeRange)
            }
        }
    }
}
