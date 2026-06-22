import Foundation
import AppKit

func test() async throws {
    let url = URL(fileURLWithPath: "/tmp/test_trash.txt")
    try! "test".write(to: url, atomically: true, encoding: .utf8)
    let result = try await NSWorkspace.shared.recycle([url])
    print("Success: \(result)")
}
Task {
    do {
        try await test()
        exit(0)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}
RunLoop.main.run()
