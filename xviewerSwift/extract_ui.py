with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

start_idx = cv_code.find("private var rightPanel: some View {")
if start_idx == -1:
    start_idx = cv_code.find("var rightPanel: some View {")

# find the matching closing brace for rightPanel
stack = 0
end_idx = -1
for i in range(start_idx, len(cv_code)):
    if cv_code[i] == '{':
        stack += 1
    elif cv_code[i] == '}':
        stack -= 1
        if stack == 0:
            end_idx = i + 1
            break

right_panel_body = cv_code[start_idx:end_idx]

# Remove rightPanel from ContentView
cv_code = cv_code[:start_idx] + cv_code[end_idx:]

# In ContentView body, replace rightPanel with PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)
cv_code = cv_code.replace("rightPanel", "PaneBrowserView(sidebarManager: sidebarManager, sidebarSelection: $sidebarSelection, session: session)")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)

# Now create PaneBrowserView.swift
pb_body = right_panel_body[right_panel_body.find("{")+1 : -1]

pb_code = f"""import SwiftUI
import UniformTypeIdentifiers

struct PaneBrowserView: View {{
    @ObservedObject var sidebarManager: SidebarManager
    @Binding var sidebarSelection: URL?
    @ObservedObject var session: BrowserSession

    var body: some View {{
{pb_body}
    }}
}}
"""

with open("xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)

print("Extracted rightPanel to PaneBrowserView")
