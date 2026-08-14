//
//  TabBarView.swift
//  xviewerSwift
//

import SwiftUI

struct TabBarView: View {
    @Binding var tabs: [WorkspaceTab]
    @Binding var activeTabID: WorkspaceTab.ID
    var maxTabs: Int = .max

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabChipView(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            canClose: tabs.count > 1,
                            onSelect: { activeTabID = tab.id },
                            onClose: { closeTab(tab) }
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
}

private struct TabChipView: View {
    @ObservedObject var tab: WorkspaceTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
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
                .stroke(isActive ? Color.blue : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
    }
}
