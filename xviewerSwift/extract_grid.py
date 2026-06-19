with open("xviewerSwift/ContentView.swift", "r") as f:
    lines = f.read().splitlines()

# find enum GridLayout
start_idx = -1
for i, line in enumerate(lines):
    if "enum GridLayout {" in line:
        start_idx = i
        break

end_idx = -1
stack = 0
for i in range(start_idx, len(lines)):
    if "{" in lines[i]:
        stack += lines[i].count("{")
    if "}" in lines[i]:
        stack -= lines[i].count("}")
        if stack == 0:
            end_idx = i
            break

# also find enum GridScrollOffset
gso_start = -1
for i, line in enumerate(lines):
    if "enum GridScrollOffset {" in line:
        gso_start = i
        break

gso_end = -1
stack = 0
for i in range(gso_start, len(lines)):
    if "{" in lines[i]:
        stack += lines[i].count("{")
    if "}" in lines[i]:
        stack -= lines[i].count("}")
        if stack == 0:
            gso_end = i
            break

# get the blocks
gl_block = "\n".join(lines[start_idx:end_idx+1])
gso_block = "\n".join(lines[gso_start:gso_end+1])

# remove them
indices_to_remove = set(range(start_idx, end_idx+1)) | set(range(gso_start, gso_end+1))
new_lines = [line for i, line in enumerate(lines) if i not in indices_to_remove]

# place them before struct ContentView
cv_start = -1
for i, line in enumerate(new_lines):
    if "struct ContentView: View {" in line:
        cv_start = i
        break

final_lines = new_lines[:cv_start] + [gl_block, "", gso_block, ""] + new_lines[cv_start:]

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write("\n".join(final_lines))

# clean up PaneBrowserView
with open("xviewerSwift/PaneBrowserView.swift", "r") as f:
    pb_code = f.read()

# I prepended them in fix_grid.py. I'll just remove them
import re
pb_code = re.sub(r'enum GridLayout \{.*?\}\n\n', '', pb_code, flags=re.DOTALL)
pb_code = re.sub(r'enum GridScrollOffset \{.*?\}\n\n', '', pb_code, flags=re.DOTALL)

with open("xviewerSwift/PaneBrowserView.swift", "w") as f:
    f.write(pb_code)

print("Done")
