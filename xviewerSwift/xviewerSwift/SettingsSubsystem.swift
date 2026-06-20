import SwiftUI

// MARK: - AppSettings
@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @AppStorage("favoritesBookmarkData") private var favoritesBookmarkData: Data = Data()
    
    @Published var favoritesURL: URL? = nil
    
    init() {
        loadFavoritesURL()
    }
    
    private func loadFavoritesURL() {
        guard !favoritesBookmarkData.isEmpty else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: favoritesBookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            favoritesURL = url
        } catch {
            print("Failed to resolve favorites bookmark: \(error)")
            favoritesURL = nil
        }
    }
    
    func setFavoritesURL(_ url: URL) {
        do {
            let isAccessed = url.startAccessingSecurityScopedResource()
            defer { if isAccessed { url.stopAccessingSecurityScopedResource() } }
            
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            favoritesBookmarkData = data
            favoritesURL = url
        } catch {
            print("Failed to create bookmark for favorites: \(error)")
        }
    }
}

// MARK: - SettingsView
struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            TabView {
                generalSettings
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                
                shortcutsSettings
                    .tabItem {
                        Label("Shortcuts", systemImage: "keyboard")
                    }
            }
            .padding(20)
        }
        .frame(width: 550, height: 450)
    }
    
    private var generalSettings: some View {
        Form {
            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(settings.favoritesURL?.path ?? "None Selected")
                            .foregroundColor(settings.favoritesURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 250, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                            .help(settings.favoritesURL?.path ?? "None Selected")
                        
                        Button("Choose...") {
                            selectFavoritesFolder()
                        }
                    }
                    
                    Text("Files marked as favorites will be moved to this folder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("Favorites Path:")
            }
        }
    }
    
    private var shortcutsSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(action: "Close / Dismiss", key: "Esc")
                ShortcutRow(action: "Toggle Split View", key: "Tab")
                ShortcutRow(action: "Navigate Up", key: "Cmd + Up Arrow")
                ShortcutRow(action: "Navigate Items", key: "Arrow Keys")
                ShortcutRow(action: "Select All", key: "Cmd + A")
                ShortcutRow(action: "Delete Item", key: "Backspace / Delete")
                ShortcutRow(action: "Create New Folder", key: "Cmd + Shift + N")
                ShortcutRow(action: "Open Selected", key: "Enter / Space")
                ShortcutRow(action: "Toggle Favorite", key: "Cmd + M")
                ShortcutRow(action: "Invert Image Colors", key: "Cmd + I")
                ShortcutRow(action: "Black & White Image", key: "Cmd + B")
                ShortcutRow(action: "Rotate Image Left", key: "Cmd + Left Arrow")
                ShortcutRow(action: "Rotate Image Right", key: "Cmd + Right Arrow")
                ShortcutRow(action: "Reset Image Rotation", key: "Delete")
            }
            .padding()
        }
    }
    
    private func selectFavoritesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the folder where favorite files will be moved"
        
        if panel.runModal() == .OK, let url = panel.url {
            settings.setFavoritesURL(url)
        }
    }
}

struct ShortcutRow: View {
    let action: String
    let key: String
    
    var body: some View {
        HStack {
            Text(action)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundColor(.secondary)
            Text("-")
                .foregroundColor(.secondary)
            Text(key)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(.body, design: .monospaced))
        }
    }
}
