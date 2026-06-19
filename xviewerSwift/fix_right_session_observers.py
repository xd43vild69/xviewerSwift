import re

with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

left_observers = """        .onChange(of: session.fullScreenImageURL) { oldURL, newURL in
            if let url = newURL {
                ImmersiveWindowController.shared.show {
                    FullScreenImageView(url: url, onClose: {
                        session.fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        session.navigateFullScreen(direction: direction)
                    })
                }
            } else {
                ImmersiveWindowController.shared.hide()
            }
        }
        .onChange(of: session.activeItemURL) { oldURL, newURL in
            session.updateMetadata(for: newURL)
        }"""

right_observers = """        .onChange(of: sessionRight.fullScreenImageURL) { oldURL, newURL in
            if let url = newURL {
                ImmersiveWindowController.shared.show {
                    FullScreenImageView(url: url, onClose: {
                        sessionRight.fullScreenImageURL = nil
                    }, navigateImage: { direction in
                        sessionRight.navigateFullScreen(direction: direction)
                    })
                }
            } else {
                if session.fullScreenImageURL == nil {
                    ImmersiveWindowController.shared.hide()
                }
            }
        }
        .onChange(of: sessionRight.activeItemURL) { oldURL, newURL in
            sessionRight.updateMetadata(for: newURL)
        }"""

# Wait, if one session closes full screen, it sets its own to nil, hiding the window.
# We should probably update the original left observer to also check if sessionRight is nil before hiding,
# but since they don't share the same full screen window simultaneously, it's fine.
# Let's just append the right_observers right after left_observers.

cv_code = cv_code.replace(left_observers, left_observers + "\n" + right_observers)

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)
