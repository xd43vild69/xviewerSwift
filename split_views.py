import re

# -------------
# PaneBrowserView
# -------------
with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb_code = f.read()

# Remove BrowserSession and other top-level stuff that is already in ContentView.swift
pb_code = re.sub(r'class BrowserSession: ObservableObject \{.*?\}\n', '', pb_code, flags=re.DOTALL)
# Remove SortOrder, FileItem, ThumbnailLoader, ThumbnailCache, FileItemView, GridScrollOffset, RubberBandSelectionGesture, GridItemCell
# Actually, those can stay in ContentView or be moved to a separate file later. For now, it's safer to leave them in ContentView and remove from PaneBrowserView.
# Wait, if they are internal, we can leave them in ContentView and just delete from PaneBrowserView.
pb_code = re.sub(r'enum SortOrder:.*?struct GridItemCell: View \{.*?\}\n\}', '', pb_code, flags=re.DOTALL)

# But wait, it's simpler to just delete EVERYTHING before `struct ContentView: View {` in PaneBrowserView.swift
idx = pb_code.find("struct ContentView: View {")
if idx != -1:
    pb_code = "import SwiftUI\nimport UniformTypeIdentifiers\nimport QuickLookThumbnailing\n\n" + pb_code[idx:]

# Rename struct
pb_code = pb_code.replace("struct ContentView: View {", "struct PaneBrowserView: View {")

# Fix properties
pb_code = pb_code.replace("@StateObject private var sidebarManager = SidebarManager()", "var sidebarManager: SidebarManager")
pb_code = pb_code.replace("@StateObject private var session = BrowserSession()", "@ObservedObject var session: BrowserSession")
pb_code = pb_code.replace("@State private var sidebarSelection: URL?", "@Binding var sidebarSelection: URL?")
pb_code = pb_code.replace("@State private var isShowingFolderPicker = false", "") # move this to ContentView

# Remove leftPanel
pb_code = re.sub(r'    private var leftPanel: some View \{.*?\}\n    \n    private var rightPanel: some View \{', '    private var rightPanel: some View {', pb_code, flags=re.DOTALL)

# In body, replace HStack(spacing: 0) { leftPanel ... rightPanel } with just rightPanel
# Find the HStack
body_start = pb_code.find("HStack(spacing: 0) {")
if body_start != -1:
    body_end = pb_code.find("}", body_start)
    body_end = pb_code.find("}", body_end + 1) # closing HStack
    pb_code = pb_code[:body_start] + "rightPanel\n" + pb_code[body_end + 1:]

# Remove .onChange(of: sidebarSelection) because that is routing from the sidebar, which is in ContentView
pb_code = re.sub(r'\s*\.onChange\(of: sidebarSelection\) \{ oldURL, newURL in.*?\}\n', '\n', pb_code, flags=re.DOTALL)
# Remove .toolbar { Select Folder } because that's global
pb_code = re.sub(r'\s*\.toolbar \{.*?\}\n', '\n', pb_code, flags=re.DOTALL)


with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)


# -------------
# ContentView
# -------------
with open("xviewerSwift/xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

# In ContentView, we want to KEEP the classes and structs at the top,
# KEEP struct ContentView, but DELETE rightPanel, shortcutsGroup, statusBar, and all methods.

# Remove everything from rightPanel to the end of the struct, EXCEPT the `body`.
# Wait, it's easier to use python ast or just regex.
# Let's find `private var rightPanel` and delete up to `var body: some View`
right_panel_idx = cv_code.find("private var rightPanel: some View {")
body_idx = cv_code.find("var body: some View {", right_panel_idx)
cv_code = cv_code[:right_panel_idx] + cv_code[body_idx:]

# In ContentView's body, we replace the HStack with PaneBrowserView
hstack_idx = cv_code.find("HStack(spacing: 0) {")
if hstack_idx != -1:
    hstack_end = cv_code.find("}", hstack_idx)
    hstack_end = cv_code.find("}", hstack_end + 1)
    
    replacement = """HStack(spacing: 0) {
                    leftPanel
                        .frame(width: mainGeometry.size.width * 0.1)
                    PaneBrowserView(sidebarManager: sidebarManager, session: session, sidebarSelection: $sidebarSelection)
                }"""
    cv_code = cv_code[:hstack_idx] + replacement + cv_code[hstack_end+1:]

# Delete shortcutsGroup, statusBar, safeAreaInset
cv_code = re.sub(r'\s*shortcutsGroup\n', '\n', cv_code)
cv_code = re.sub(r'\s*\.safeAreaInset\(edge: \.bottom\) \{.*?\}\n', '\n', cv_code, flags=re.DOTALL)

# Remove all methods after the body in ContentView (since they moved to PaneBrowserView)
# Find the end of `body` by brace counting
body_start = cv_code.find("var body: some View {")
brace_count = 0
in_body = False
body_end_idx = -1
for i in range(body_start, len(cv_code)):
    if cv_code[i] == '{':
        brace_count += 1
        in_body = True
    elif cv_code[i] == '}':
        brace_count -= 1
        if in_body and brace_count == 0:
            body_end_idx = i
            break

if body_end_idx != -1:
    # Delete everything after body_end_idx until the last closing brace of ContentView
    last_brace = cv_code.rfind("}")
    cv_code = cv_code[:body_end_idx + 1] + "\n}\n"

# Clean up variables in ContentView that are now in PaneBrowserView
# isShowingProperties, etc.
cv_code = re.sub(r'\s*@State private var currentColumnCount: Int = 1\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var isShowingProperties = false\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var propertiesURL: URL\?\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var isShowingSingleRenameAlert = false\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var singleRenameBaseName: String = ""\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var itemToRename: URL\?\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var isShowingBulkRenameAlert = false\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var bulkRenameBaseName: String = ""\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var showCopiedFeedback: Bool = false\n', '\n', cv_code)
cv_code = re.sub(r'\s*@State private var folderHistory: \[URL: URL\] = \[:\]\n', '\n', cv_code)
cv_code = re.sub(r'\s*private var imageItems: \[FileItem\].*?\}\n', '\n', cv_code, flags=re.DOTALL)

with open("xviewerSwift/xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)

print("Split complete")
