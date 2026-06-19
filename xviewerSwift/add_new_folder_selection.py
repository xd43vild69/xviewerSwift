import re

# 1. Update BrowserSession.swift
with open("xviewerSwift/BrowserSession.swift", "r") as f:
    bs = f.read()

new_folder_func = """    func createNewFolderWithSelection() {
        guard let currentDir = self.currentFolderURL, !self.selectedItemURLs.isEmpty else { return }
        
        let fm = FileManager.default
        var newFolderName = "new folder"
        var finalURL = currentDir.appendingPathComponent(newFolderName)
        var counter = 1
        
        while fm.fileExists(atPath: finalURL.path) {
            newFolderName = "new folder \(counter)"
            finalURL = currentDir.appendingPathComponent(newFolderName)
            counter += 1
        }
        
        do {
            try fm.createDirectory(at: finalURL, withIntermediateDirectories: true, attributes: nil)
            
            let itemsToMove = Array(self.selectedItemURLs)
            for itemURL in itemsToMove {
                let destURL = finalURL.appendingPathComponent(itemURL.lastPathComponent)
                try fm.moveItem(at: itemURL, to: destURL)
            }
            
            loadFolder(url: currentDir, sidebarManager: nil)
            
            DispatchQueue.main.async {
                self.selectedItemURLs = [finalURL]
                self.activeItemURL = finalURL
                self.promptSingleRename(for: finalURL)
            }
            
        } catch {
            print("Error creating folder with selection: \(error)")
            NSSound.beep()
        }
    }
"""

if "func createNewFolderWithSelection" not in bs:
    bs = bs.replace("    func createNewFolder() {", new_folder_func + "\n    func createNewFolder() {")

with open("xviewerSwift/BrowserSession.swift", "w") as f:
    f.write(bs)

# 2. Update ContentView.swift (GridItemCell)
with open("xviewerSwift/ContentView.swift", "r") as f:
    cv = f.read()

cv = cv.replace("let createNewFolderAction: () -> Void", "let createNewFolderAction: () -> Void\n    let newFolderWithSelectionAction: () -> Void")

menu_btn = """            if !selectedItemURLs.isEmpty {
                Button { newFolderWithSelectionAction() } label: {
                    Label("New Folder with Selection (\(selectedItemURLs.count) items)", systemImage: "folder.badge.plus")
                }
            }"""

cv = cv.replace("Button { createNewFolderAction() } label: {\n                Label(\"New Folder\", systemImage: \"folder.badge.plus\")\n            }", 
                "Button { createNewFolderAction() } label: {\n                Label(\"New Folder\", systemImage: \"folder.badge.plus\")\n            }\n" + menu_btn)

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv)

# 3. Update PaneBrowserView.swift
with open("xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb = f.read()

pb = pb.replace("createNewFolderAction: {\n                                    session.createNewFolder()\n                                },", 
                "createNewFolderAction: {\n                                    session.createNewFolder()\n                                },\n                                newFolderWithSelectionAction: {\n                                    session.createNewFolderWithSelection()\n                                },")

with open("xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb)

