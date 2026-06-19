import Foundation

let path = "/Users/d13/Documents/code/xviewerSwift/xviewerSwift/xviewerSwift/ContentView.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)

let target = """
        var moves: [(URL, URL)] = []
"""
let replacement = """
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Debug: Renaming \\(filesToRename.count) files"
            alert.runModal()
        }
        var moves: [(URL, URL)] = []
"""
if content.contains(target) && !content.contains("Debug: Renaming") {
    content = content.replacingOccurrences(of: target, with: replacement)
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
    print("Patched.")
} else {
    print("Target not found or already patched.")
}
