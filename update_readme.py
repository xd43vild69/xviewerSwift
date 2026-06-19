import re

with open("README.md", "r") as f:
    readme = f.read()

dual_pane = """### 🪟 Dual Pane (Split View)
- **Side-by-Side Browsing:** Press `Cmd + S` or use the toolbar button to activate a dual-pane layout for simultaneous, independent browsing of two folders.
- **Quick Transfer:** Move files instantly between the active and inactive pane using `Option + Left/Right Arrow` shortcuts. The destination pane refreshes automatically.
- **Smart Focus:** Click anywhere or press `Tab` to seamlessly switch focus between the left and right panels.

"""

# Insert Dual Pane before ### 🧭 Navigation
readme = readme.replace("### 🧭 Navigation & Organization", dual_pane + "### 🧭 Navigation & Organization")

krita_old = "- **Open with Krita:** Dedicated integration to send images directly to the Krita digital painting application for advanced editing."
krita_new = """- **Open with Krita:** Dedicated integration to send images directly to the Krita digital painting application for advanced editing.
- **Open with Lightroom:** Right-click an image to send its corresponding RAW file directly to Adobe Lightroom for professional color grading. Automatically handles temporary workspace staging."""

readme = readme.replace(krita_old, krita_new)

with open("README.md", "w") as f:
    f.write(readme)
