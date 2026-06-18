import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

struct PropertiesView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    @State private var metadataText: String = "Extracting metadata..."
    @State private var showCopiedFeedback = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Properties")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
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
            
            ScrollView {
                Text(metadataText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding()
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
