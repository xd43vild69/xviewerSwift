import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv = f.read()

# Fix the broken ones. I need to find `setupKeyboardMonitor() loadImage(from: url) }` and fix it.
cv = cv.replace("setupKeyboardMonitor() loadImage(from: url)", "loadImage(from: url)")
cv = cv.replace("setupKeyboardMonitor() self.currentFolderURL = url", "self.currentFolderURL = url")
# Just remove ALL occurrences of setupKeyboardMonitor() and re-insert carefully
cv = cv.replace("            setupKeyboardMonitor()\n", "")

# Let's insert it only in the root ZStack's onAppear or the main View's onAppear.
# The main view body ends around line 900.
# We will insert `.onAppear { setupKeyboardMonitor() }` right after `.background(Color.black.ignoresSafeArea())`
# Wait, the best place is on `ContentView` main body.

main_body_end = """        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {"""

new_main_body_end = """        }
        .onAppear {
            setupKeyboardMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {"""

cv = cv.replace(main_body_end, new_main_body_end)

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv)
