with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

gl_start = cv_code.find("enum GridLayout {")
gl_end = cv_code.find("}", gl_start) + 1

gso_start = cv_code.find("enum GridScrollOffset {")
gso_end = cv_code.find("}", gso_start) + 1

grid_layout_code = cv_code[gl_start:gl_end]
grid_scroll_offset_code = cv_code[gso_start:gso_end]

cv_code = cv_code[:gl_start] + cv_code[gl_end:gso_start] + cv_code[gso_end:]

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)

with open("xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb_code = f.read()

# Add them above struct PaneBrowserView
pb_code = pb_code.replace("struct PaneBrowserView", grid_layout_code + "\n\n" + grid_scroll_offset_code + "\n\nstruct PaneBrowserView")
pb_code = pb_code.replace("session.session.propertiesURL", "session.propertiesURL")

with open("xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)
