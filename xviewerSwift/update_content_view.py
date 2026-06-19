import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

# 1. Add moveSelectionToOtherPane method
move_method = """
    private func moveSelectionToOtherPane(direction: ActivePane) {
        guard isSplitViewEnabled else { return }
        
        let sourceSession = (direction == .right) ? session : sessionRight
        let destSession = (direction == .right) ? sessionRight : session
        
        guard let sourceFolder = sourceSession.currentFolderURL,
              let destFolder = destSession.currentFolderURL else { return }
              
        if sourceFolder == destFolder {
            sourceSession.showNotification("Cannot move: Source and destination are the same folder")
            return
        }
        
        let urlsToMove = Array(sourceSession.selectedItemURLs)
        if urlsToMove.isEmpty { return }
        
        sourceSession.moveFiles(urls: urlsToMove, to: destFolder)
    }
"""
if "func moveSelectionToOtherPane" not in cv_code:
    cv_code = cv_code.replace("private func activeSession() -> BrowserSession {", move_method + "\n    private func activeSession() -> BrowserSession {")


# 2. Add shortcuts
shortcuts = """
            Button(action: {
                if isSplitViewEnabled {
                    moveSelectionToOtherPane(direction: .right)
                }
            }) { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .opacity(0)
                
            Button(action: {
                if isSplitViewEnabled {
                    moveSelectionToOtherPane(direction: .left)
                }
            }) { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .opacity(0)
"""

cv_code = cv_code.replace('Button(action: { activeSession().navigateUp() }) { Text("") }', shortcuts + '\n            Button(action: { activeSession().navigateUp() }) { Text("") }')


# 3. Add notification overlay to the ZStack
notification_overlay = """
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if let msg = activeSession().notificationMessage {
                            Text(msg)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.8))
                                .cornerRadius(8)
                                .shadow(radius: 4)
                                .padding(.bottom, 30)
                                .padding(.trailing, 20)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .zIndex(1)
                        }
                    }
                }
"""

cv_code = cv_code.replace("shortcutsGroup\n            }", "shortcutsGroup\n" + notification_overlay + "\n            }")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)
