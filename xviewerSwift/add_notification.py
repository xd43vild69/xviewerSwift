import re

with open("xviewerSwift/BrowserSession.swift", "r") as f:
    bs_code = f.read()

show_notification_func = """
    func showNotification(_ message: String) {
        notificationMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.notificationMessage == message {
                self.notificationMessage = nil
            }
        }
    }
"""

# Insert before moveFiles
bs_code = bs_code.replace("func moveFiles(urls:", show_notification_func + "\n    func moveFiles(urls:")

with open("xviewerSwift/BrowserSession.swift", "w") as f:
    f.write(bs_code)
