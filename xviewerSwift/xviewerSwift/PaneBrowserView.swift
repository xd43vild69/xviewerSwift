import SwiftUI
import UniformTypeIdentifiers

struct PaneBrowserView: View {
    @ObservedObject var sidebarManager: SidebarManager
    @Binding var sidebarSelection: URL?
    @ObservedObject var session: BrowserSession
    @State private var scrollDebounceTask: Task<Void, Never>?

    var body: some View {

        GeometryReader { geometry in
            let columns = GridLayout.columnCount(for: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100)), count: columns), spacing: GridLayout.spacing) {
                        ForEach(session.folderContents) { item in
                            GridItemCell(
                                item: item,
                                isSelected: session.selectedItemURLs.contains(item.url),
                                selectedItemURLs: $session.selectedItemURLs,
                                activeItemURL: $session.activeItemURL,
                                fullScreenImageURL: $session.fullScreenImageURL,
                                currentSortOrder: $session.currentSortOrder,
                                loadFolderAction: { url in
                                    sidebarSelection = nil
                                    session.loadFolder(url: url, sidebarManager: sidebarManager)
                                },
                                moveItemAction: { url in
                                    session.moveItem(url)
                                },
                                createNewFolderAction: {
                                    session.createNewFolder()
                                },
                                newFolderWithSelectionAction: {
                                    session.createNewFolderWithSelection()
                                },
                                openWithKritaAction: { url in
                                    session.openWithKrita(url)
                                },
                                openWithLightroomAction: { url in
                                    session.openWithLightroom(url)
                                },
                                renameItemAction: { url in
                                    if session.selectedItemURLs.count > 1 && session.selectedItemURLs.contains(url) {
                                        session.promptBulkRename()
                                    } else {
                                        session.promptSingleRename(for: url)
                                    }
                                },
                                showPropertiesAction: { url in
                                    session.propertiesURL = url
                                    session.isShowingProperties = true
                                },
                                isBookmarked: sidebarManager.bookmarks.contains(where: { $0.url == item.url }),
                                toggleBookmarkAction: {
                                    if sidebarManager.bookmarks.contains(where: { $0.url == item.url }) {
                                        sidebarManager.unpinFolder(url: item.url)
                                    } else {
                                        sidebarManager.pinFolder(url: item.url)
                                    }
                                },
                                isSingleSelection: session.selectedItemURLs.count == 1 && session.selectedItemURLs.contains(item.url),
                                performDropAction: { destinationURL in
                                    let urlsToMove = Array(session.selectedItemURLs)
                                    session.moveFiles(urls: urlsToMove, to: destinationURL)
                                },
                                updateSelectionAnchorAction: { url in
                                    session.updateSelectionAnchor(url)
                                },
                                isActive: session.activeItemURL == item.url
                            )
                            .id(item.url)
                        }
                    }
                    .environment(\.thumbnailLoader, session.thumbnailLoader)
                    .padding(GridLayout.padding)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    GridScrollOffset.contentMinY = geo.frame(in: .named("GridSpace")).minY
                                }
                                .onChange(of: geo.frame(in: .named("GridSpace")).minY) { _, minY in
                                    GridScrollOffset.contentMinY = minY
                                    session.isScrolling = true
                                    scrollDebounceTask?.cancel()
                                    scrollDebounceTask = Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 150_000_000)
                                        guard !Task.isCancelled else { return }
                                        session.isScrolling = false
                                    }
                                }
                        }
                    )
                    .environment(\.isScrolling, session.isScrolling)
                }
                .coordinateSpace(name: "GridSpace")
                .rubberBandSelection(
                    selectedItemURLs: $session.selectedItemURLs,
                    activeItemURL: $session.activeItemURL,
                    folderContents: session.folderContents,
                    columns: columns,
                    viewportWidth: geometry.size.width
                )
                .onChange(of: session.activeItemURL) { oldURL, newURL in
                    if let url = newURL {
                        proxy.scrollTo(url)
                    }
                }
                .onChange(of: session.folderContents) { _, newContents in
                    if !newContents.isEmpty, let url = session.activeItemURL {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(url)
                        }
                    }
                }
            }
            .onChange(of: geometry.size.width) { oldWidth, newWidth in
                session.currentColumnCount = GridLayout.columnCount(for: newWidth)
            }
            .onChange(of: session.currentSortOrder) { oldOrder, newOrder in
                session.folderContents = session.sortItems(session.folderContents)
            }
            .onAppear {
                session.currentColumnCount = columns
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            session.selectedItemURLs.removeAll()
            session.activeItemURL = nil
        }
        .contextMenu {
            Button { session.currentSortOrder = .name } label: {
                Label("Order by name", systemImage: session.currentSortOrder == .name ? "checkmark" : "")
            }
            Button { session.currentSortOrder = .date } label: {
                Label("Order by date", systemImage: session.currentSortOrder == .date ? "checkmark" : "")
            }
            Button { session.currentSortOrder = .size } label: {
                Label("Order by size", systemImage: session.currentSortOrder == .size ? "checkmark" : "")
            }
            Divider()
            Button { session.createNewFolder() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button { session.promptBulkRename() } label: {
                Label(session.selectedItemURLs.count > 1 ? "Rename \(session.selectedItemURLs.count) Items..." : "Rename All...", systemImage: "pencil.line")
            }
            if !session.imageItems.isEmpty {
                Divider()
                Button { session.partitionCurrentFolder() } label: {
                    Label("Partitioning (100 imgs/folder)", systemImage: "rectangle.split.3x1")
                }
            }
        }
    
    }
}
