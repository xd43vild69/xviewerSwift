import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

move_old = """        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
    }"""

move_new = """        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
        
        // Refresh destination panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            destSession.loadFolder(url: destFolder, sidebarManager: self.sidebarManager)
        }
    }"""

cv_code = cv_code.replace(move_old, move_new)

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)
