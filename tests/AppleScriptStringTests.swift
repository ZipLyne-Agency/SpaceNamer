import Foundation

private func expect(_ actual: String, _ expected: String, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected.debugDescription), got \(actual.debugDescription)\n", stderr)
        exit(1)
    }
}

@main
struct AppleScriptStringTests {
    static func main() {
        expect(appleScriptStringLiteral("https://example.com/a"), "\"https://example.com/a\"", "plain URL")
        expect(appleScriptStringLiteral("https://example.com/?q=\"quoted\""), "\"https://example.com/?q=\\\"quoted\\\"\"", "quotes")
        expect(appleScriptStringLiteral("https://example.com/a\\b"), "\"https://example.com/a\\\\b\"", "backslashes")
        expect(appleScriptStringLiteral("line1\nline2"), "\"line1\\nline2\"", "newlines")
        print("AppleScript string tests passed")
    }
}
