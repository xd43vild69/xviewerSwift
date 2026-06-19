import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv = f.read()

# Remove all upArrow/downArrow/leftArrow/rightArrow shortcuts from ContentView
cv = re.sub(r'\s*Button\(action: \{ activeSession\(\)\.handle\w+\(.*?\).*?\.keyboardShortcut\(\.\w+Arrow, modifiers: \[\]\).*?\.opacity\(0\)', '', cv)

# Add onAppear NSEvent monitor to ContentView
event_monitor = """    @State private var eventMonitor: Any?

    private func setupKeyboardMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let shiftPressed = event.modifierFlags.contains(.shift)
                switch event.keyCode {
                case 123: // Left arrow
                    activeSession().handleLeftArrow(shift: shiftPressed)
                    return nil // consume event
                case 124: // Right arrow
                    activeSession().handleRightArrow(shift: shiftPressed)
                    return nil
                case 125: // Down arrow
                    activeSession().handleDownArrow(shift: shiftPressed)
                    return nil
                case 126: // Up arrow
                    activeSession().handleUpArrow(shift: shiftPressed)
                    return nil
                default:
                    return event
                }
            }
        }
    }
"""

if "setupKeyboardMonitor" not in cv:
    cv = cv.replace("private func activeSession() -> BrowserSession {", event_monitor + "\n    private func activeSession() -> BrowserSession {")
    cv = cv.replace(".onAppear {", ".onAppear {\n            setupKeyboardMonitor()")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv)
