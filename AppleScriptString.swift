import Foundation

/// Returns a quoted AppleScript string literal without allowing captured browser
/// data to terminate the string or inject additional script statements.
func appleScriptStringLiteral(_ value: String) -> String {
    var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
    escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
    escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
    escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}
