import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

# 1. Remove BrowserSession block
bs_match = re.search(r'^class BrowserSession: ObservableObject \{.*?^\}', cv_code, re.DOTALL | re.MULTILINE)
if bs_match:
    cv_code = cv_code[:bs_match.start()] + cv_code[bs_match.end():]

# 2. Remove methods
m_start = cv_code.find("private func copySelectedItemToClipboard()")
m_end = cv_code.rfind("}", 0, cv_code.find("#Preview"))
if m_start != -1 and m_end != -1:
    cv_code = cv_code[:m_start] + cv_code[m_end:]

# 3. Clean up properties
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
    r'\s*private var imageItems: \[FileItem\] \{\n.*?\n    \}\n'
]
for pattern in to_remove:
    cv_code = re.sub(pattern, '\n', cv_code, flags=re.DOTALL)

# 4. Update closures
cv_code = re.sub(r'(?<!\.)loadFolder\(url: (.*?)\)', r'session.loadFolder(url: \1, sidebarManager: sidebarManager)', cv_code)
cv_code = re.sub(r'(?<!\.)moveItem\(url\)', 'session.moveItem(url)', cv_code)
cv_code = cv_code.replace("createNewFolder()", "session.createNewFolder()")
cv_code = cv_code.replace("openWithKrita(url)", "session.openWithKrita(url)")
cv_code = cv_code.replace("openWithLightroom(url)", "session.openWithLightroom(url)")
cv_code = cv_code.replace("promptBulkRename()", "session.promptBulkRename()")
cv_code = cv_code.replace("promptSingleRename(for: url)", "session.promptSingleRename(for: url)")
cv_code = cv_code.replace("propertiesURL = url", "session.propertiesURL = url")
cv_code = cv_code.replace("isShowingProperties = true", "session.isShowingProperties = true")
cv_code = cv_code.replace("moveFiles(urls: urlsToMove, to: destinationURL)", "session.moveFiles(urls: urlsToMove, to: destinationURL)")
cv_code = cv_code.replace("sortItems(session.folderContents)", "session.sortItems(session.folderContents)")
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
cv_code = cv_code.replace("showCopiedFeedback = true", "session.showCopiedFeedback = true")
cv_code = cv_code.replace("showCopiedFeedback = false", "session.showCopiedFeedback = false")
cv_code = cv_code.replace("showCopiedFeedback ? 0.3 : 1.0", "session.showCopiedFeedback ? 0.3 : 1.0")
cv_code = cv_code.replace("if showCopiedFeedback", "if session.showCopiedFeedback")
cv_code = cv_code.replace("imageItems.count", "session.imageItems.count")
cv_code = cv_code.replace("$isShowingProperties", "$session.isShowingProperties")
cv_code = cv_code.replace("propertiesURL", "session.propertiesURL")
cv_code = cv_code.replace("$isShowingSingleRenameAlert", "$session.isShowingSingleRenameAlert")
cv_code = cv_code.replace("$singleRenameBaseName", "$session.singleRenameBaseName")
cv_code = cv_code.replace("$itemToRename", "$session.itemToRename")
cv_code = cv_code.replace("$isShowingBulkRenameAlert", "$session.isShowingBulkRenameAlert")
cv_code = cv_code.replace("$bulkRenameBaseName", "$session.bulkRenameBaseName")
cv_code = cv_code.replace("executeSingleRename(originalURL: session.itemToRename!, newBaseName: session.singleRenameBaseName)", "session.executeSingleRename(originalURL: session.itemToRename!, newBaseName: session.singleRenameBaseName)")
cv_code = cv_code.replace("executeBulkRename(baseName: session.bulkRenameBaseName)", "session.executeBulkRename(baseName: session.bulkRenameBaseName)")
cv_code = cv_code.replace("executeSingleRename(originalURL: url, newBaseName: newName)", "session.executeSingleRename(originalURL: url, newBaseName: newName)")
cv_code = cv_code.replace("executeBulkRename(baseName: newName)", "session.executeBulkRename(baseName: newName)")
cv_code = cv_code.replace("saveBookmark(", "session.saveBookmark(")
cv_code = cv_code.replace("restoreBookmark()", "session.restoreBookmark()")
cv_code = cv_code.replace("updateMetadata(", "session.updateMetadata(")
cv_code = cv_code.replace("navigateFullScreen(", "session.navigateFullScreen(")

# 5. Extract rightPanel
start_idx = cv_code.find("private var rightPanel: some View {")
if start_idx == -1:
    start_idx = cv_code.find("var rightPanel: some View {")

if start_idx != -1:
    stack = 0
    end_idx = -1
    for i in range(start_idx, len(cv_code)):
        if cv_code[i] == '{':
            stack += 1
        elif cv_code[i] == '}':
            stack -= 1
            if stack == 0:
                end_idx = i + 1
                break
    
    cv_code = cv_code[:start_idx] + cv_code[end_idx:]
    cv_code = cv_code.replace("rightPanel", "PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)
