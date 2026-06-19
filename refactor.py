import re

with open("xviewerSwift/xviewerSwift/ContentView.swift", "r") as f:
    code = f.read()

# Define the state variables to replace
vars_to_replace = [
    "currentFolderURL",
    "folderContents",
    "fullScreenImageURL",
    "selectedItemURLs",
    "activeItemURL",
    "currentSortOrder",
    "metadataString",
    "otherFileCount"
]

# 1. Add BrowserSession class before ContentView
session_class = """
class BrowserSession: ObservableObject {
    @Published var currentFolderURL: URL?
    @Published var folderContents: [FileItem] = []
    @Published var fullScreenImageURL: URL?
    @Published var selectedItemURLs: Set<URL> = []
    @Published var activeItemURL: URL?
    @Published var currentSortOrder: SortOrder = .name
    @Published var metadataString: String = ""
    @Published var otherFileCount: Int = 0
}

"""

if "class BrowserSession" not in code:
    code = code.replace("struct ContentView: View {", session_class + "struct ContentView: View {")

# 2. Replace state declarations
code = re.sub(r'(\s*)@State private var currentFolderURL: URL\?', r'\1@StateObject private var session = BrowserSession()', code)
code = re.sub(r'\s*@State private var folderContents: \[FileItem\] = \[\]\n', '\n', code)
code = re.sub(r'\s*@State private var fullScreenImageURL: URL\?\n', '\n', code)
code = re.sub(r'\s*@State private var selectedItemURLs: Set<URL> = \[\]\n', '\n', code)
code = re.sub(r'\s*@State private var activeItemURL: URL\?\n', '\n', code)
code = re.sub(r'\s*@State private var currentSortOrder: SortOrder = \.name\n', '\n', code)
code = re.sub(r'\s*@State private var metadataString: String = ""\n', '\n', code)
code = re.sub(r'\s*@State private var otherFileCount: Int = 0\n', '\n', code)

# 3. Replace usages
# We need to be careful not to replace them where they are declared as arguments (e.g. in FileItemCell)
# but wait, they are not declared as these exact names in FileItemCell, except bindings.
# Let's replace only as word boundaries, and avoiding 'var ' or 'let ' or '$'.
# Wait, for Bindings like `$selectedItemURLs`, we need to replace with `$session.selectedItemURLs`.

for v in vars_to_replace:
    # Replace $var with $session.var
    code = re.sub(r'\$' + v + r'\b', f'$session.{v}', code)
    # Replace var with session.var, but not if it's preceded by 'var ', 'let ', '.', or inside a parameter list like `url in`
    # We use a negative lookbehind for dot, 'var ', 'let ', 'self.', etc.
    code = re.sub(r'(?<![.\w])' + v + r'\b(?!:)', f'session.{v}', code)

with open("xviewerSwift/xviewerSwift/ContentView.swift", "w") as f:
    f.write(code)

print("Refactoring complete.")
