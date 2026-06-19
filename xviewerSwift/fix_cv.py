with open("xviewerSwift/ContentView.swift", "r") as f:
    cv_code = f.read()

cv_code = cv_code.replace("saveBookmark(", "session.saveBookmark(")
cv_code = cv_code.replace("restoreBookmark()", "session.restoreBookmark()")
cv_code = cv_code.replace("updateMetadata(", "session.updateMetadata(")
cv_code = cv_code.replace("navigateFullScreen(", "session.navigateFullScreen(")

with open("xviewerSwift/ContentView.swift", "w") as f:
    f.write(cv_code)
