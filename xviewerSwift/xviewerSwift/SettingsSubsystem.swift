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
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("General & File Operations").font(.headline).foregroundColor(.secondary)
                    ShortcutRow(action: "Select Folder", key: "Cmd + O")
                    ShortcutRow(action: "Select All Items", key: "Cmd + A")
                    ShortcutRow(action: "Select All (Items & Folders)", key: "Cmd + Control + A")
                    ShortcutRow(action: "Copy Item", key: "Cmd + C")
                    ShortcutRow(action: "Paste Item", key: "Cmd + V")
                    ShortcutRow(action: "Move Item", key: "Cmd + Shift + V / Cmd + Option + V")
                    ShortcutRow(action: "Delete Item", key: "Backspace / Delete / Cmd + Backspace")
                    ShortcutRow(action: "Undo Last Action", key: "Cmd + Z")
                    ShortcutRow(action: "Create New Folder", key: "Cmd + Shift + N")
                    ShortcutRow(action: "Rename Item", key: "F2")
                    ShortcutRow(action: "Filter (Toggle)", key: "F3")
                    ShortcutRow(action: "Context Menu", key: "Cmd + /")
                    ShortcutRow(action: "Mount SMB Server", key: "Cmd + K")
                }

                Divider().padding(.vertical, 8)

                Group {
                    Text("Navigation").font(.headline).foregroundColor(.secondary)
                    ShortcutRow(action: "Navigate Grid", key: "Arrow Keys")
                    ShortcutRow(action: "Multi-Select", key: "Shift + Arrow Keys")
                    ShortcutRow(action: "Open Selected", key: "Enter / Space / Cmd + Down")
                    ShortcutRow(action: "Navigate Up Folder", key: "Cmd + Up")
                    ShortcutRow(action: "Navigate Back", key: "Cmd + Left")
                    ShortcutRow(action: "Navigate Forward", key: "Cmd + Right")
                    ShortcutRow(action: "Jump to First Item", key: "Cmd + [ (or Cmd + Shift + Up)")
                    ShortcutRow(action: "Jump to Last Item", key: "Cmd + ] (or Cmd + Shift + Down)")
                    ShortcutRow(action: "Jump to Item by Letter", key: "Letter Key (A-Z, 0-9)")
                }

                Divider().padding(.vertical, 8)

                Group {
                    Text("Split View").font(.headline).foregroundColor(.secondary)
                    ShortcutRow(action: "Toggle Split View", key: "Cmd + S")
                    ShortcutRow(action: "Switch Active Pane", key: "Tab")
                    ShortcutRow(action: "Move to Left Pane", key: "Option + Left")
                    ShortcutRow(action: "Move to Right Pane", key: "Option + Right")
                    ShortcutRow(action: "Copy to Left Pane", key: "Cmd + Option + Left")
                    ShortcutRow(action: "Copy to Right Pane", key: "Cmd + Option + Right")
                    ShortcutRow(action: "Select Tabs for Split Merge", key: "Cmd + Click (2 tabs), then \"Split\"")
                }

                Divider().padding(.vertical, 8)

                Group {
                    Text("Full-Screen Image Viewer").font(.headline).foregroundColor(.secondary)
                    ShortcutRow(action: "Close Viewer", key: "Esc")
                    ShortcutRow(action: "Toggle UI", key: "Tab")
                    ShortcutRow(action: "Previous/Next Image", key: "Arrow Keys")
                    ShortcutRow(action: "Copy to Favorites", key: "Cmd + M")
                    ShortcutRow(action: "Invert Colors", key: "Cmd + I")
                    ShortcutRow(action: "Black & White", key: "Cmd + B")
                    ShortcutRow(action: "Flip Horizontal", key: "Cmd + H")
                    ShortcutRow(action: "Rotate Left", key: "Cmd + Left")
                    ShortcutRow(action: "Rotate Right", key: "Cmd + Right")
                    ShortcutRow(action: "Reset Rotation", key: "Delete")
                    ShortcutRow(action: "Cycle Background Color", key: "Cmd + 1")
                }
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
