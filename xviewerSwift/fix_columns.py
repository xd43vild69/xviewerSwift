import re

with open("xviewerSwift/PaneBrowserView.swift", "r") as f:
    code = f.read()

old_onChange = """            .onChange(of: columns) { oldValue, newValue in
                session.currentColumnCount = newValue
            }"""

new_onChange = """            .onChange(of: geometry.size.width) { oldWidth, newWidth in
                session.currentColumnCount = GridLayout.columnCount(for: newWidth)
            }"""

code = code.replace(old_onChange, new_onChange)

with open("xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(code)
