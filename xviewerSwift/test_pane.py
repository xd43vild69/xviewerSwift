with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb_code = f.read()

# Comment out rubberBandSelection
import re
pb_code = re.sub(r'(\.rubberBandSelection\()', r'//\1', pb_code)

with open("xviewerSwift/xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)
