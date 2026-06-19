import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv = f.read()

# 1. Remove the explicit shift shortcuts
cv = re.sub(r'\s*Button\(action: \{ activeSession\(\)\.handle\w+\(shift: true\) \}\) \{ Text\(""\) \}\n\s*\.keyboardShortcut\(\.\w+, modifiers: \[\.shift\]\)\n\s*\.opacity\(0\)', '', cv)

# 2. Update the base shortcuts to read NSEvent
cv = cv.replace("activeSession().handleUpArrow()", "activeSession().handleUpArrow(shift: NSEvent.modifierFlags.contains(.shift))")
cv = cv.replace("activeSession().handleDownArrow()", "activeSession().handleDownArrow(shift: NSEvent.modifierFlags.contains(.shift))")
cv = cv.replace("activeSession().handleLeftArrow()", "activeSession().handleLeftArrow(shift: NSEvent.modifierFlags.contains(.shift))")
cv = cv.replace("activeSession().handleRightArrow()", "activeSession().handleRightArrow(shift: NSEvent.modifierFlags.contains(.shift))")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv)
