import re

with open("xviewerSwift/BrowserSession.swift", "r") as f:
    bs = f.read()

# 1. Update handlers
bs = bs.replace("func handleUpArrow() {", "func handleUpArrow(shift: Bool = false) {")
bs = bs.replace("func handleDownArrow() {", "func handleDownArrow(shift: Bool = false) {")
bs = bs.replace("func handleLeftArrow() {", "func handleLeftArrow(shift: Bool = false) {")
bs = bs.replace("func handleRightArrow() {", "func handleRightArrow(shift: Bool = false) {")

bs = bs.replace("navigateGridRow(direction: -1)", "navigateGridRow(direction: -1, shift: shift)")
bs = bs.replace("navigateGridRow(direction: 1)", "navigateGridRow(direction: 1, shift: shift)")
bs = bs.replace("navigateGrid(direction: -1)", "navigateGrid(direction: -1, shift: shift)")
bs = bs.replace("navigateGrid(direction: 1)", "navigateGrid(direction: 1, shift: shift)")

# 2. Update navigate functions
bs = bs.replace("func navigateGridRow(direction: Int) {", "func navigateGridRow(direction: Int, shift: Bool) {")
bs = bs.replace("func navigateGrid(direction: Int) {", "func navigateGrid(direction: Int, shift: Bool) {")

# 3. Update assignment logic in navigateGridRow
old_row_logic = """        if newIndex >= 0 && newIndex < self.folderContents.count {
            self.activeItemURL = self.folderContents[newIndex].url; self.selectedItemURLs = [self.folderContents[newIndex].url]
        } else if newIndex < 0 {
            if let u = self.folderContents.first?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
        } else if newIndex >= self.folderContents.count {
            if let u = self.folderContents.last?.url { self.activeItemURL = u; self.selectedItemURLs = [u] }
        }"""
new_row_logic = """        var targetURL: URL? = nil
        if newIndex >= 0 && newIndex < self.folderContents.count {
            targetURL = self.folderContents[newIndex].url
        } else if newIndex < 0 {
            targetURL = self.folderContents.first?.url
        } else if newIndex >= self.folderContents.count {
            targetURL = self.folderContents.last?.url
        }
        
        if let newURL = targetURL {
            self.activeItemURL = newURL
            if shift {
                self.selectedItemURLs.insert(newURL)
            } else {
                self.selectedItemURLs = [newURL]
            }
        }"""
bs = bs.replace(old_row_logic, new_row_logic)

# 4. Update assignment logic in navigateGrid
old_grid_logic = """        if newIndex >= 0 && newIndex < self.folderContents.count {
            self.activeItemURL = self.folderContents[newIndex].url; self.selectedItemURLs = [self.folderContents[newIndex].url]
        }"""
new_grid_logic = """        if newIndex >= 0 && newIndex < self.folderContents.count {
            let newURL = self.folderContents[newIndex].url
            self.activeItemURL = newURL
            if shift {
                self.selectedItemURLs.insert(newURL)
            } else {
                self.selectedItemURLs = [newURL]
            }
        }"""
bs = bs.replace(old_grid_logic, new_grid_logic)

with open("xviewerSwift/BrowserSession.swift", "w") as f:
    f.write(bs)

# 5. Update ContentView.swift to add Shift shortcuts
with open("xviewerSwift/ContentView.swift", "r") as f:
    cv = f.read()

# Add shift versions
shift_shortcuts = """
            Button(action: { activeSession().handleUpArrow(shift: true) }) { Text("") }
                .keyboardShortcut(.upArrow, modifiers: [.shift])
                .opacity(0)
                
            Button(action: { activeSession().handleDownArrow(shift: true) }) { Text("") }
                .keyboardShortcut(.downArrow, modifiers: [.shift])
                .opacity(0)
                
            Button(action: { activeSession().handleLeftArrow(shift: true) }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .opacity(0)
                
            Button(action: { activeSession().handleRightArrow(shift: true) }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .opacity(0)
"""

cv = cv.replace("Button(action: { activeSession().handleUpArrow() }) { Text(\"\") }", shift_shortcuts + "\n            Button(action: { activeSession().handleUpArrow() }) { Text(\"\") }")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv)

