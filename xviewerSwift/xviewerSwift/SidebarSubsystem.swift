import SwiftUI
import CoreFoundation
import UniformTypeIdentifiers

// MARK: - 1. ARQUITECTURA DE DATOS (Model & Enum)

enum SidebarSection: String, CaseIterable {
    case sources = "Sources"
    case bookmarks = "Bookmarks"
    case recent = "Recents"
}

struct SidebarFolderItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let systemIcon: String
    var visitCount: Int = 1
    var bookmarkData: Data? = nil
}

struct PersistedSidebarItem: Codable {
    let name: String
    let systemIcon: String
    let visitCount: Int
    let bookmarkData: Data
}

// MARK: - 2. GESTOR DE ESTADO DESACOPLADO (SidebarManager)

@MainActor
class SidebarManager: ObservableObject {
    @Published var sources: [SidebarFolderItem] = []
    @Published var bookmarks: [SidebarFolderItem] = []
    @Published var recent: [SidebarFolderItem] = []
    
    private let bookmarksKey = "sidebar_bookmarks_v1"
    private let recentKey = "sidebar_recent_v1"

    init() {
        loadDefaultSources()
        loadState()
    }
    
    private func loadDefaultSources() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Pictures")
        
        self.sources = [
            SidebarFolderItem(url: home, name: "Home", systemIcon: "house"),
            SidebarFolderItem(url: downloads, name: "Descargas", systemIcon: "arrow.down.circle"),
            SidebarFolderItem(url: pictures, name: "Imágenes", systemIcon: "photo.on.rectangle")
        ]
    }
    
    /// Búfer por Frecuencia de Uso (Max: 7) para carpetas recientes
    func recordRecentVisit(url: URL) {
        if let index = recent.firstIndex(where: { $0.url == url }) {
            var item = recent.remove(at: index)
            item.visitCount += 1
            recent.insert(item, at: 0)
        } else {
            let bData = createBookmark(for: url)
            let newItem = SidebarFolderItem(url: url, name: url.lastPathComponent, systemIcon: "clock", visitCount: 1, bookmarkData: bData)
            recent.insert(newItem, at: 0)
        }
        
        // Ordenamiento descendente por peso de frecuencia (Frequency Metric)
        recent.sort { $0.visitCount > $1.visitCount }
        
        while recent.count > 7 {
            let removed = recent.removeLast()
            removed.url.stopAccessingSecurityScopedResource()
        }
        saveState()
    }
    
    func pinFolder(url: URL) {
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        let bData = createBookmark(for: url)
        let newItem = SidebarFolderItem(url: url, name: url.lastPathComponent, systemIcon: "bookmark.fill", visitCount: 1, bookmarkData: bData)
        bookmarks.append(newItem)
        saveState()
    }
    
    func unpinFolder(url: URL) {
        url.stopAccessingSecurityScopedResource()
        bookmarks.removeAll { $0.url == url }
        saveState()
    }
    
    private func createBookmark(for url: URL) -> Data? {
        do {
            let isAccessed = url.startAccessingSecurityScopedResource()
            defer { if isAccessed { url.stopAccessingSecurityScopedResource() } }
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            do {
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                return nil
            }
        }
    }
    
    func makeSecureURL(_ url: URL) -> URL {
        guard let bData = createBookmark(for: url) else { return url }
        var isStale = false
        if let secureURL = try? URL(resolvingBookmarkData: bData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = secureURL.startAccessingSecurityScopedResource()
            return secureURL
        }
        return url
    }

    // MARK: - Persistence
    
    private func saveState() {
        saveItems(bookmarks, forKey: bookmarksKey)
        saveItems(recent, forKey: recentKey)
    }
    
    private func loadState() {
        bookmarks = loadItems(forKey: bookmarksKey)
        
        let loadedRecent = loadItems(forKey: recentKey)
        recent = loadedRecent.map { item in
            var modifiedItem = item
            modifiedItem.visitCount = 1
            return modifiedItem
        }
    }
    
    private func saveItems(_ items: [SidebarFolderItem], forKey key: String) {
        let persistedItems = items.compactMap { item -> PersistedSidebarItem? in
            guard let data = item.bookmarkData ?? createBookmark(for: item.url) else { return nil }
            return PersistedSidebarItem(name: item.name, systemIcon: item.systemIcon, visitCount: item.visitCount, bookmarkData: data)
        }
        if let encoded = try? JSONEncoder().encode(persistedItems) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    private func loadItems(forKey key: String) -> [SidebarFolderItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let persistedItems = try? JSONDecoder().decode([PersistedSidebarItem].self, from: data) else {
            return []
        }
        
        var loadedItems: [SidebarFolderItem] = []
        for pItem in persistedItems {
            var isStale = false
            var url: URL?
            do {
                url = try URL(resolvingBookmarkData: pItem.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            } catch {
                print("Failed to resolve secure bookmark: \(error)")
                continue
            }
            if let validURL = url {
                _ = validURL.startAccessingSecurityScopedResource()
                let item = SidebarFolderItem(url: validURL, name: pItem.name, systemIcon: pItem.systemIcon, visitCount: pItem.visitCount, bookmarkData: pItem.bookmarkData)
                loadedItems.append(item)
            }
        }
        return loadedItems
    }
}

// MARK: - 3. COMPONENTE DE INTERFAZ DE USUARIO (SidebarNavigationView)

struct SidebarNavigationView: View {
    @ObservedObject var manager: SidebarManager
    @Binding var selectedFolderURL: URL?
    var performDropAction: ((URL) -> Void)?
    
    @State private var isShowingSettings = false
    
    var body: some View {
        List(selection: $selectedFolderURL) {
            
            // Sección: Fuentes
            Section(header: Text(SidebarSection.sources.rawValue)) {
                ForEach(manager.sources) { item in
                    SidebarItemRow(item: item, performDropAction: performDropAction)
                        .tag(item.url)
                }
            }
            
            // Sección: Marcadores
            Section(header: Text(SidebarSection.bookmarks.rawValue)) {
                ForEach(manager.bookmarks) { item in
                    SidebarItemRow(item: item, performDropAction: performDropAction)
                        .tag(item.url)
                        .contextMenu {
                            Button(role: .destructive) {
                                manager.unpinFolder(url: item.url)
                            } label: {
                                Label("Eliminar Marcador", systemImage: "trash")
                            }
                        }
                }
            }
            
            // Sección: Recientes
            Section(header: Text(SidebarSection.recent.rawValue)) {
                ForEach(manager.recent) { item in
                    SidebarItemRow(item: item, performDropAction: performDropAction)
                        .tag(item.url)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: {
                    isShowingSettings = true
                }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(PlainButtonStyle())
                .padding()
                
                Spacer()
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }
}

// Componente visual aislado para mantener limpio el List principal
fileprivate struct SidebarItemRow: View {
    let item: SidebarFolderItem
    var performDropAction: ((URL) -> Void)?
    
    @State private var isTargeted: Bool = false
    
    var body: some View {
        Label(item.name, systemImage: item.systemIcon)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
            .cornerRadius(4)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                performDropAction?(item.url)
                return true
            }
    }
}
