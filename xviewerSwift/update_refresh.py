import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

move_method_old = """        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
    }"""

move_method_new = """        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
        
        // Refresh destination panel
        destSession.refresh()
    }"""

# Actually, let's verify if `refresh` exists in BrowserSession.
# I'll just change it anyway. Wait, if `refresh()` doesn't exist, I should use `loadFolder(url: destFolder, sidebarManager: sidebarManager)`.
# Let's check `BrowserSession.swift` first to see if `refresh()` exists.
