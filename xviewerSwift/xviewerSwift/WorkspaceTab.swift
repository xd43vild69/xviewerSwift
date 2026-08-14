//
//  WorkspaceTab.swift
//  xviewerSwift
//

import AppKit

/// Estado de un tab: una copia independiente del par de paneles (izquierdo/derecho)
/// que antes vivía directamente en ContentView. Cada tab tiene sus propias
/// BrowserSession, por lo que folder/selección/historial/scroll se preservan
/// aunque el tab no esté activo.
@MainActor
final class WorkspaceTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var sidebarSelection: URL?
    @Published var sidebarSelectionRight: URL?
    @Published var isSplitViewEnabled = false
    @Published var activePane: ActivePane = .left
    let session = BrowserSession()
    let sessionRight = BrowserSession()

    init(id: UUID = UUID()) {
        self.id = id
    }

    var title: String {
        session.currentFolderURL?.lastPathComponent ?? "New Tab"
    }

    // MARK: - Persistencia

    /// Snapshot serializable del tab. Solo se guardan URLs (como security-scoped
    /// bookmarks, igual que SidebarManager/BrowserSession) y flags — nunca las
    /// BrowserSession completas, que tienen estado transitorio (caches, alerts).
    struct Snapshot: Codable {
        let id: UUID
        let sidebarSelectionBookmark: Data?
        let sidebarSelectionRightBookmark: Data?
        let isSplitViewEnabled: Bool
    }

    func makeSnapshot() -> Snapshot {
        Snapshot(
            id: id,
            sidebarSelectionBookmark: Self.secureBookmark(for: sidebarSelection),
            sidebarSelectionRightBookmark: Self.secureBookmark(for: sidebarSelectionRight),
            isSplitViewEnabled: isSplitViewEnabled
        )
    }

    /// Reconstruye un tab desde un snapshot. Solo asigna las URLs de sidebar —
    /// el folder real se carga perezosamente cuando el tab se monta (WorkspaceView
    /// observa sidebarSelection), así restaurar N tabs no dispara N cargas de disco
    /// al arrancar: solo el tab activo carga.
    convenience init?(snapshot: Snapshot) {
        self.init(id: snapshot.id)
        guard let url = Self.resolveSecureBookmark(snapshot.sidebarSelectionBookmark) else {
            return nil
        }
        self.sidebarSelection = url
        self.sidebarSelectionRight = Self.resolveSecureBookmark(snapshot.sidebarSelectionRightBookmark)
        self.isSplitViewEnabled = snapshot.isSplitViewEnabled && self.sidebarSelectionRight != nil
    }

    private static func secureBookmark(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveSecureBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              (try? url.checkResourceIsReachable()) == true else { return nil }
        return url
    }
}

/// Guarda y restaura la sesión de tabs en UserDefaults.
@MainActor
enum TabSessionStore {
    private static let tabsKey = "workspaceTabSnapshots"
    private static let activeTabKey = "workspaceActiveTabID"

    static func save(tabs: [WorkspaceTab], activeTabID: WorkspaceTab.ID) {
        let snapshots = tabs.map { $0.makeSnapshot() }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: tabsKey)
        }
        UserDefaults.standard.set(activeTabID.uuidString, forKey: activeTabKey)
    }

    /// Devuelve los tabs restaurados y el ID del tab que estaba activo.
    /// Los snapshots cuya carpeta ya no existe (o cuyo bookmark expiró) se descartan.
    static func restore() -> (tabs: [WorkspaceTab], activeTabID: WorkspaceTab.ID)? {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let snapshots = try? JSONDecoder().decode([WorkspaceTab.Snapshot].self, from: data) else {
            return nil
        }
        let tabs = snapshots.compactMap { WorkspaceTab(snapshot: $0) }
        guard !tabs.isEmpty else { return nil }

        let activeID = UserDefaults.standard.string(forKey: activeTabKey).flatMap(UUID.init(uuidString:))
        let active = tabs.first(where: { $0.id == activeID })?.id ?? tabs[0].id
        return (tabs, active)
    }
}
