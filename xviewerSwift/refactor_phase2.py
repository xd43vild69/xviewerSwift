import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

# 1. Extract BrowserSession class block
bs_start = cv_code.find("class BrowserSession: ObservableObject {")
bs_end = cv_code.find("}", bs_start) + 1
browser_session_base = cv_code[bs_start:bs_end]

# Delete BrowserSession from ContentView
cv_code = cv_code[:bs_start] + cv_code[bs_end:]

# 2. Extract methods from line 1236 (copySelectedItemToClipboard) down to the end before #Preview
methods_start_idx = cv_code.find("private func copySelectedItemToClipboard()")
preview_idx = cv_code.find("#Preview {")
methods_end_idx = cv_code.rfind("}", 0, preview_idx) # The closing brace of ContentView

methods_code = cv_code[methods_start_idx:methods_end_idx]

# 3. Modify methods code for BrowserSession
methods_code = methods_code.replace("self.session.", "self.")
methods_code = methods_code.replace("session.", "self.")
methods_code = methods_code.replace("private func", "func")
# handle loadFolder signature
methods_code = methods_code.replace("func loadFolder(url: URL)", "func loadFolder(url: URL, sidebarManager: SidebarManager?)")
methods_code = methods_code.replace("sidebarManager.recordRecentVisit", "sidebarManager?.recordRecentVisit")
# handle sidebarSelection = nil inside navigateUp and handleEnter
methods_code = re.sub(r'\s*sidebarSelection = nil\n', '\n', methods_code)
# remove any stray self.loadFolder calls missing sidebarManager
methods_code = re.sub(r'self\.loadFolder\(url: (.*?)\)', r'self.loadFolder(url: \1, sidebarManager: nil)', methods_code)
methods_code = re.sub(r'loadFolder\(url: (.*?)\)', r'loadFolder(url: \1, sidebarManager: nil)', methods_code)

# 4. Construct BrowserSession.swift
bs_properties = """
    @Published var isShowingProperties = false
    @Published var propertiesURL: URL?
    
    @Published var isShowingSingleRenameAlert = false
    @Published var singleRenameBaseName: String = ""
    @Published var itemToRename: URL?

    @Published var isShowingBulkRenameAlert = false
    @Published var bulkRenameBaseName: String = ""
    @Published var showCopiedFeedback: Bool = false
    @Published var folderHistory: [URL: URL] = [:]

    var imageItems: [FileItem] {
        folderContents.filter { !$0.isDirectory }
    }
"""

bs_full = "import SwiftUI\nimport UniformTypeIdentifiers\nimport QuickLookThumbnailing\n\n"
bs_full += browser_session_base[:-1] + bs_properties + "\n" + methods_code + "\n}\n"

with open("xviewerSwift/BrowserSession.swift", "w") as f:
    f.write(bs_full)

# 5. Clean up ContentView
# Remove methods
cv_code = cv_code[:methods_start_idx] + cv_code[methods_end_idx:]

# Remove @State properties that were moved to BrowserSession
to_remove = [
    r'\s*@State private var isShowingProperties = false\n',
    r'\s*@State private var propertiesURL: URL\?\n',
    r'\s*@State private var isShowingSingleRenameAlert = false\n',
    r'\s*@State private var singleRenameBaseName: String = ""\n',
    r'\s*@State private var itemToRename: URL\?\n',
    r'\s*@State private var isShowingBulkRenameAlert = false\n',
    r'\s*@State private var bulkRenameBaseName: String = ""\n',
    r'\s*@State private var showCopiedFeedback: Bool = false\n',
    r'\s*@State private var folderHistory: \[URL: URL\] = \[:\]\n',
    r'\s*private var imageItems: \[FileItem\].*?\}\n'
]
for pattern in to_remove:
    cv_code = re.sub(pattern, '\n', cv_code, flags=re.DOTALL)

# In ContentView's closures, call session.method instead of method
cv_code = cv_code.replace("loadFolder(url: url)", "session.loadFolder(url: url, sidebarManager: sidebarManager)")
cv_code = cv_code.replace("moveItem(url)", "session.moveItem(url)")
cv_code = cv_code.replace("createNewFolder()", "session.createNewFolder()")
cv_code = cv_code.replace("openWithKrita(url)", "session.openWithKrita(url)")
cv_code = cv_code.replace("openWithLightroom(url)", "session.openWithLightroom(url)")
cv_code = cv_code.replace("promptBulkRename()", "session.promptBulkRename()")
cv_code = cv_code.replace("promptSingleRename(for: url)", "session.promptSingleRename(for: url)")
cv_code = cv_code.replace("propertiesURL = url", "session.propertiesURL = url")
cv_code = cv_code.replace("isShowingProperties = true", "session.isShowingProperties = true")
cv_code = cv_code.replace("moveFiles(urls: urlsToMove, to: destinationURL)", "session.moveFiles(urls: urlsToMove, to: destinationURL)")
cv_code = cv_code.replace("sortItems(session.folderContents)", "session.sortItems(session.folderContents)")

# update shortcuts
cv_code = cv_code.replace("navigateUp()", "session.navigateUp()")
cv_code = cv_code.replace("handleUpArrow()", "session.handleUpArrow()")
cv_code = cv_code.replace("handleDownArrow()", "session.handleDownArrow()")
cv_code = cv_code.replace("handleLeftArrow()", "session.handleLeftArrow()")
cv_code = cv_code.replace("handleRightArrow()", "session.handleRightArrow()")
cv_code = cv_code.replace("handleEnter()", "session.handleEnter()")
cv_code = cv_code.replace("copySelectedItemToClipboard()", "session.copySelectedItemToClipboard()")
cv_code = cv_code.replace("pasteFromClipboard()", "session.pasteFromClipboard()")
cv_code = cv_code.replace("deleteSelectedItem()", "session.deleteSelectedItem()")
cv_code = cv_code.replace("selectAllItems()", "session.selectAllItems()")

# update statusBar properties
cv_code = cv_code.replace("showCopiedFeedback = true", "session.showCopiedFeedback = true")
cv_code = cv_code.replace("showCopiedFeedback = false", "session.showCopiedFeedback = false")
cv_code = cv_code.replace("showCopiedFeedback ? 0.3 : 1.0", "session.showCopiedFeedback ? 0.3 : 1.0")
cv_code = cv_code.replace("if showCopiedFeedback", "if session.showCopiedFeedback")
cv_code = cv_code.replace("imageItems.count", "session.imageItems.count")

# update properties sheet inside body
cv_code = cv_code.replace("$isShowingProperties", "$session.isShowingProperties")
cv_code = cv_code.replace("propertiesURL", "session.propertiesURL")

# fix alerts
cv_code = cv_code.replace("$isShowingSingleRenameAlert", "$session.isShowingSingleRenameAlert")
cv_code = cv_code.replace("$singleRenameBaseName", "$session.singleRenameBaseName")
cv_code = cv_code.replace("$isShowingBulkRenameAlert", "$session.isShowingBulkRenameAlert")
cv_code = cv_code.replace("$bulkRenameBaseName", "$session.bulkRenameBaseName")

# execute renames
cv_code = cv_code.replace("executeSingleRename(originalURL: session.itemToRename!, newBaseName: session.singleRenameBaseName)", "session.executeSingleRename(originalURL: session.itemToRename!, newBaseName: session.singleRenameBaseName)")
cv_code = cv_code.replace("executeBulkRename(baseName: session.bulkRenameBaseName)", "session.executeBulkRename(baseName: session.bulkRenameBaseName)")


with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)

print("Refactored into BrowserSession.swift")
