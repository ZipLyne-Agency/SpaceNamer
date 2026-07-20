import Foundation

private struct Value: Codable, Equatable {
    let name: String
}

@main
struct JSONStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacenamer-json-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("value.json")
        try writeJSONAtomically(Value(name: "saved"), to: file)
        let decoded = try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
        guard decoded == Value(name: "saved") else { fatalError("round trip failed") }

        do {
            try writeJSONAtomically(Value(name: "must fail"), to: directory)
            fatalError("writing JSON to a directory unexpectedly succeeded")
        } catch CocoaError.fileWriteFileExists {
            // Expected failure is surfaced to the caller.
        } catch {
            // Filesystem versions may choose a different Cocoa write error.
        }
        print("JSON store tests passed")
    }
}
