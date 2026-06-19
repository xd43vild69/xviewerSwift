import Foundation

let path = "/Users/d13/Documents/code/xviewerSwift/xviewerSwift/xviewerSwift/ContentView.swift"
var content = try! String(contentsOfFile: path)

let target = """
        Task { await processRenames(moves: moves) }
"""
let replacement = """
        let logStr = moves.map { "\\($0.0.lastPathComponent) -> \\($0.1.lastPathComponent)" }.joined(separator: "\\n")
        try? logStr.write(toFile: "/tmp/rename_log.txt", atomically: true, encoding: .utf8)
        Task { await processRenames(moves: moves) }
"""
if content.contains(target) {
    content = content.replacingOccurrences(of: target, with: replacement)
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
    print("Patched.")
} else {
    print("Target not found.")
}
