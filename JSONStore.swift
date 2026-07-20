import Foundation

func writeJSONAtomically<Value: Encodable>(_ value: Value, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: url, options: .atomic)
}
