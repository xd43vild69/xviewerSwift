//
//  TabBarView.swift
//  xviewerSwift
//

import SwiftUI

struct TabBarView: View {
    @Binding var tabs: [WorkspaceTab]
    @Binding var activeTabID: WorkspaceTab.ID
    var maxTabs: Int = .max

    /// Tabs marcados para combinar en split view (⌘+clic o "Select for Split" del menú).
    @State private var selectedTabIDs: Set<WorkspaceTab.ID> = []

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabChipView(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            isMarkedForSplit: selectedTabIDs.contains(tab.id),
                            canClose: tabs.count > 1,
                            canSplitSelected: selectedTabIDs.count == 2 && selectedTabIDs.contains(tab.id),
                            onSelect: { selectTab(tab) },
                            onToggleMarkForSplit: { toggleMarkForSplit(tab) },
                            onClose: { closeTab(tab) },
                            onSplitSelected: splitSelectedTabs
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            Button(action: newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help("New Tab (⌘T)")
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .background(
            Group {
                Button(action: newTab) { Text("") }
                    .keyboardShortcut("t", modifiers: [.command])
                    .opacity(0)
                Button(action: closeActiveTab) { Text("") }
                    .keyboardShortcut("w", modifiers: [.command])
                    .opacity(0)
                Button(action: { cycleTab(by: 1) }) { Text("") }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .opacity(0)
                Button(action: { cycleTab(by: -1) }) { Text("") }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .opacity(0)
            }
        )
        .onChange(of: tabs.map(\.id)) { _, newIDs in
            // Si un tab se cierra por otra vía, no dejar referencias colgantes en la marca de split.
            selectedTabIDs = selectedTabIDs.intersection(newIDs)
        }
    }

    private func selectTab(_ tab: WorkspaceTab) {
        activeTabID = tab.id
    }

    private func toggleMarkForSplit(_ tab: WorkspaceTab) {
        if selectedTabIDs.contains(tab.id) {
            selectedTabIDs.remove(tab.id)
        } else if selectedTabIDs.count < 2 {
            selectedTabIDs.insert(tab.id)
        } else {
            // Ya hay 2 marcados: reemplaza el más antiguo para poder rearmar la selección.
            selectedTabIDs.removeFirst()
            selectedTabIDs.insert(tab.id)
        }
    }

    private func newTab() {
        guard tabs.count < maxTabs else {
            NSSound.beep()
            return
        }
        let tab = WorkspaceTab()
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func closeActiveTab() {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else { return }
        closeTab(tab)
    }

    private func closeTab(_ tab: WorkspaceTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if activeTabID == tab.id {
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
    }

    private func cycleTab(by offset: Int) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let count = tabs.count
        let newIndex = ((currentIndex + offset) % count + count) % count
        activeTabID = tabs[newIndex].id
    }

    /// Crea un tab NUEVO en split view con las carpetas de los 2 tabs marcados:
    /// el que aparece primero en la barra va al panel izquierdo (principal) y el
    /// segundo al panel derecho. Los tabs originales quedan intactos.
    private func splitSelectedTabs() {
        let ordered = tabs.filter { selectedTabIDs.contains($0.id) }
        guard ordered.count == 2 else { return }
        guard tabs.count < maxTabs else {
            NSSound.beep()
            return
        }

        // currentFolderURL es la carpeta realmente visible; sidebarSelection solo
        // cambia al elegir desde el sidebar, no al navegar con doble clic.
        guard let leftURL = ordered[0].session.currentFolderURL ?? ordered[0].sidebarSelection,
              let rightURL = ordered[1].session.currentFolderURL ?? ordered[1].sidebarSelection else {
            NSSound.beep()
            return
        }

        let combined = WorkspaceTab()
        combined.sidebarSelection = leftURL
        combined.sidebarSelectionRight = rightURL
        combined.isSplitViewEnabled = true
        combined.activePane = .left

        tabs.append(combined)
        activeTabID = combined.id
        selectedTabIDs = []
    }
}

private struct TabChipView: View {
    @ObservedObject var tab: WorkspaceTab
    let isActive: Bool
    let isMarkedForSplit: Bool
    let canClose: Bool
    let canSplitSelected: Bool
    let onSelect: () -> Void
    let onToggleMarkForSplit: () -> Void
    let onClose: () -> Void
    let onSplitSelected: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if isMarkedForSplit {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)

            if isHovering && canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.blue.opacity(0.25) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.blue : (isMarkedForSplit ? Color.orange : Color.clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                onToggleMarkForSplit()
            } else {
                onSelect()
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isMarkedForSplit ? "Deselect for Split" : "Select for Split") {
                onToggleMarkForSplit()
            }
            if canSplitSelected {
                Divider()
                Button("Split Selected") { onSplitSelected() }
            }
            if canClose {
                Divider()
                Button("Close Tab") { onClose() }
            }
        }
        .help("⌘+click to select two tabs for Split Selected")
    }
}
