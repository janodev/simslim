import Foundation

func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

func writeJSON<T: Encodable>(_ value: T) throws {
    try FileHandle.standardOutput.write(contentsOf: encodedJSON(value))
}
