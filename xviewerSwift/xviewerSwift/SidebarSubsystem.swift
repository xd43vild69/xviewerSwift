import SwiftUI
import CoreFoundation

// MARK: - 1. ARQUITECTURA DE DATOS (Model & Enum)

enum SidebarSection: String, CaseIterable {
    case sources = "Fuentes"
    case bookmarks = "Marcadores"
    case recent = "Recientes"
}

struct SidebarFolderItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let systemIcon: String
    var visitCount: Int = 1
}

// MARK: - 2. GESTOR DE ESTADO DESACOPLADO (SidebarManager)

@MainActor
class SidebarManager: ObservableObject {
    @Published var sources: [SidebarFolderItem] = []
    @Published var bookmarks: [SidebarFolderItem] = []
    @Published var recent: [SidebarFolderItem] = []
    
    init() {
        loadDefaultSources()
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
            recent[index].visitCount += 1
        } else {
            let newItem = SidebarFolderItem(url: url, name: url.lastPathComponent, systemIcon: "clock", visitCount: 1)
            recent.append(newItem)
        }
        
        // Ordenamiento descendente por peso de frecuencia (Frequency Metric)
        recent.sort { $0.visitCount > $1.visitCount }
        
        if recent.count > 7 {
            recent.removeLast()
        }
    }
    
    func pinFolder(url: URL) {
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        let newItem = SidebarFolderItem(url: url, name: url.lastPathComponent, systemIcon: "bookmark.fill")
        bookmarks.append(newItem)
    }
    
    func unpinFolder(url: URL) {
        bookmarks.removeAll { $0.url == url }
    }
}

// MARK: - 3. COMPONENTE DE INTERFAZ DE USUARIO (SidebarNavigationView)

struct SidebarNavigationView: View {
    @StateObject private var manager = SidebarManager()
    @Binding var selectedFolderURL: URL?
    
    var body: some View {
        List(selection: $selectedFolderURL) {
            
            // Sección: Fuentes
            Section(header: Text(SidebarSection.sources.rawValue)) {
                ForEach(manager.sources) { item in
                    SidebarItemRow(item: item)
                        .tag(item.url)
                }
            }
            
            // Sección: Marcadores
            Section(header: Text(SidebarSection.bookmarks.rawValue)) {
                ForEach(manager.bookmarks) { item in
                    SidebarItemRow(item: item)
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
                    SidebarItemRow(item: item)
                        .tag(item.url)
                }
            }
        }
        .listStyle(.sidebar)
        // Capturamos el cambio de carpeta global para alimentar el FIFO de Recientes
        .onChange(of: selectedFolderURL) { oldURL, newURL in
            if let targetURL = newURL {
                manager.recordRecentVisit(url: targetURL)
            }
        }
    }
}

// Componente visual aislado para mantener limpio el List principal
fileprivate struct SidebarItemRow: View {
    let item: SidebarFolderItem
    
    var body: some View {
        Label(item.name, systemImage: item.systemIcon)
    }
}
