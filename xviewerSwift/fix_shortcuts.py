import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

# 1. Add activePane state
active_pane_enum = """
enum ActivePane {
    case left
    case right
}
"""

if "enum ActivePane" not in cv_code:
    # insert above struct ContentView
    cv_code = cv_code.replace("struct ContentView: View {", active_pane_enum + "\nstruct ContentView: View {")

if "@State private var activePane" not in cv_code:
    cv_code = cv_code.replace("@State private var isSplitViewEnabled = false", 
                              "@State private var isSplitViewEnabled = false\n    @State private var activePane: ActivePane = .left")

# 2. Add activeSession() method
active_session_func = """
    private func activeSession() -> BrowserSession {
        if isSplitViewEnabled && activePane == .right {
            return sessionRight
        }
        return session
    }
"""
if "func activeSession()" not in cv_code:
    # insert before shortcutsGroup
    cv_code = cv_code.replace("private var shortcutsGroup: some View {", active_session_func + "\n    private var shortcutsGroup: some View {")

# 3. Replace session. with activeSession(). in shortcutsGroup
start_idx = cv_code.find("private var shortcutsGroup: some View {")
end_idx = cv_code.find("private var statusBar: some View {")

shortcuts_code = cv_code[start_idx:end_idx]
shortcuts_code = shortcuts_code.replace("action: { session.", "action: { activeSession().")
cv_code = cv_code[:start_idx] + shortcuts_code + cv_code[end_idx:]

# 4. Add simultaneousGesture to PaneBrowserViews
cv_code = cv_code.replace("""PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)""",
"""PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                                .simultaneousGesture(TapGesture().onEnded { activePane = .left })""")

cv_code = cv_code.replace("""PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelectionRight, session: sessionRight)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)""",
"""PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelectionRight, session: sessionRight)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                                .simultaneousGesture(TapGesture().onEnded { activePane = .right })""")


with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)

print("Done")
