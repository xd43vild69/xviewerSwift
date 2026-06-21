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
    var lastVisitDate: Date = Date.now
    var isCurrentSessionVisit: Bool = true
    var bookmarkData: Data? = nil
}

struct PersistedSidebarItem: Codable {
    let name: String
    let systemIcon: String
    let visitCount: Int
    let lastVisitDate: Date
    let bookmarkData: Data
}

// MARK: - 2. GESTOR DE ESTADO DESACOPLADO (SidebarManager)

@MainActor
class SidebarManager: ObservableObject {
    @Published var sources: [SidebarFolderItem] = []
    @Published var bookmarks: [SidebarFolderItem] = []
    @Published var recent: [SidebarFolderItem] = []

    private let bookmarksKey = "sidebar_bookmarks_v1"
    private let recentKey = "sidebar_recent_v2"

    private let maxRecentItems = 13
    private let recencyWeightDays = 30.0

    init() {
        loadDefaultSources()
        loadState()
    }

    // MARK: - Scoring & Sorting (Hybrid Frequency + Recency)

    private func calculateScore(for item: SidebarFolderItem) -> Double {
        // Frecuencia normalizada (rango esperado: 1-50 visitas)
        let normalizedFrequency = min(Double(item.visitCount) / 50.0, 1.0)
        let frequencyScore = normalizedFrequency * 0.6  // 60% del peso

        // Recencia basada en lastVisitDate
        let daysSinceLastVisit = Date.now.timeIntervalSince(item.lastVisitDate) / 86400.0
        let recencyScore: Double

        if daysSinceLastVisit < 1 {  // hoy
            recencyScore = 1.0
        } else if daysSinceLastVisit < 7 {  // esta semana
            recencyScore = 0.9 - (daysSinceLastVisit / 7.0) * 0.2
        } else if daysSinceLastVisit < 30 {  // este mes
            recencyScore = 0.7 - (daysSinceLastVisit / 30.0) * 0.5
        } else {  // más antiguos
            recencyScore = max(0.2 - (daysSinceLastVisit / 90.0), 0.0)
        }
        let recencyWeight = recencyScore * 0.4  // 40% del peso

        // ✨ NUEVO: Ajuste por profundidad y contexto de navegación
        let depthAndContextBonus = calculateDepthAndContextBonus(for: item)

        return frequencyScore + recencyWeight + depthAndContextBonus
    }

    private func calculateDepthAndContextBonus(for item: SidebarFolderItem) -> Double {
        // Bonus por profundidad: carpetas más profundas (específicas) son más valiosas
        let pathComponents = item.url.pathComponents.count
        let depthBonus = min(Double(pathComponents) / 10.0, 0.2)  // Max 0.2 bonus

        // Detectar si hay subcarpetas activas (visitadas en sesión actual)
        let hasActiveChildren = recent.contains { child in
            child.isCurrentSessionVisit &&
            child.url.path.hasPrefix(item.url.path) &&
            child.url.path != item.url.path
        }

        // Si hay hijas activas en sesión, penalizar la padre para priorizar hijas
        if hasActiveChildren {
            return depthBonus * 0.3  // Reduce significativamente el bonus
        }

        return depthBonus
    }

    private func sortRecents() {
        // Separar: sesión actual vs histórico
        let currentSession = recent.filter { $0.isCurrentSessionVisit }
        let historical = recent.filter { !$0.isCurrentSessionVisit }

        // Ordenar cada grupo por score
        let sortedCurrent = currentSession.sorted {
            calculateScore(for: $0) > calculateScore(for: $1)
        }
        let sortedHistorical = historical.sorted {
            calculateScore(for: $0) > calculateScore(for: $1)
        }

        // Concatenar: sesión actual primero, luego histórico
        recent = sortedCurrent + sortedHistorical
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
    
    /// Registro de visita con algoritmo híbrido (frecuencia + recencia, max 13)
    func recordRecentVisit(url: URL) {
        if let index = recent.firstIndex(where: { $0.url == url }) {
            var item = recent.remove(at: index)
            item.visitCount += 1
            item.lastVisitDate = Date.now
            item.isCurrentSessionVisit = true
            recent.insert(item, at: 0)
        } else {
            let bData = createBookmark(for: url)
            let newItem = SidebarFolderItem(
                url: url,
                name: url.lastPathComponent,
                systemIcon: "clock",
                visitCount: 1,
                lastVisitDate: Date.now,
                isCurrentSessionVisit: true,
                bookmarkData: bData
            )
            recent.insert(newItem, at: 0)
        }

        // Re-ordenar con lógica híbrida (frecuencia + recencia, sesión actual primero)
        sortRecents()

        // Limitar a 13 items máximo
        while recent.count > maxRecentItems {
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
            // Reseteo suave por sesión: el conteo arranca en 1 para que el histórico
            // no domine. Se conserva lastVisitDate → las últimas rutas siguen visibles
            // por recencia. A medida que el usuario trabaja en esta sesión, las visitas
            // vuelven a contar y suben por encima del histórico.
            modifiedItem.visitCount = 1
            modifiedItem.isCurrentSessionVisit = false
            return modifiedItem
        }
    }
    
    private func saveItems(_ items: [SidebarFolderItem], forKey key: String) {
        let persistedItems = items.compactMap { item -> PersistedSidebarItem? in
            guard let data = item.bookmarkData ?? createBookmark(for: item.url) else { return nil }
            return PersistedSidebarItem(
                name: item.name,
                systemIcon: item.systemIcon,
                visitCount: item.visitCount,
                lastVisitDate: item.lastVisitDate,
                bookmarkData: data
            )
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
                url = try URL(resolvingBookmarkData: pItem.bookmarkData, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale)
                if let resolvedURL = url, !((try? resolvedURL.checkResourceIsReachable()) ?? false) {
                    continue
                }
            } catch {
                print("Failed to resolve secure bookmark: \(error)")
                continue
            }
            if let validURL = url {
                _ = validURL.startAccessingSecurityScopedResource()
                let item = SidebarFolderItem(
                    url: validURL,
                    name: pItem.name,
                    systemIcon: pItem.systemIcon,
                    visitCount: pItem.visitCount,
                    lastVisitDate: pItem.lastVisitDate,
                    isCurrentSessionVisit: false,
                    bookmarkData: pItem.bookmarkData
                )
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
        HStack {
            Label(item.name, systemImage: item.systemIcon)
            Spacer()
            if item.visitCount > 1 {
                Text("\(item.visitCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
            }
        }
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
