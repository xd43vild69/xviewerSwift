with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb_code = f.read()

# Comment out .contextMenu
import re
pb_code = re.sub(r'(\.contextMenu \{.*?\n        \})', r'/* \1 */', pb_code, flags=re.DOTALL)
# Comment out .onTapGesture
pb_code = re.sub(r'(\.onTapGesture \{.*?\n        \})', r'/* \1 */', pb_code, flags=re.DOTALL)
# Comment out .onChange(of: columns)
pb_code = re.sub(r'(\.onChange\(of: columns\) \{.*?\n            \})', r'/* \1 */', pb_code, flags=re.DOTALL)
# Comment out .onChange(of: session.currentSortOrder)
pb_code = re.sub(r'(\.onChange\(of: session\.currentSortOrder\) \{.*?\n            \})', r'/* \1 */', pb_code, flags=re.DOTALL)
# Comment out .onAppear
pb_code = re.sub(r'(\.onAppear \{.*?\n            \})', r'/* \1 */', pb_code, flags=re.DOTALL)
# Comment out .background(Color.clear)
pb_code = re.sub(r'\s*\.background\(Color\.clear\)\n', '\n', pb_code)
# Comment out .contentShape(Rectangle())
pb_code = re.sub(r'\s*\.contentShape\(Rectangle\(\)\)\n', '\n', pb_code)

with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)
