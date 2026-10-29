import Foundation

public enum HexError: Error {
    case oddLength
    case notHexadecimal
}

/// Data bytes that follow the status of a channel voice message (0x80...0xEF) or a system common message; 0 for
/// everything else, F0 included (SysEx has no fixed length).
func dataLength(ofStatus status: UInt8) -> Int {
    switch status {
    case 0xC0...0xDF, 0xF1, 0xF3: 1
    case 0x80...0xBF, 0xE0...0xEF, 0xF2: 2
    default: 0
    }
}

/// Splits a byte stream into complete MIDI messages, so each goes to CoreMIDI as one packet.
public func splitMessages(_ data: [UInt8]) -> [[UInt8]] {
    var messages: [[UInt8]] = []
    var index = 0
    while index < data.count {
        let status = data[index]
        if status < 0x80 {  // a stray data byte without a status: nothing to send it with
            index += 1
            continue
        }
        let end =
            status == 0xF0
            ? data[index...].firstIndex(of: 0xF7) ?? data.count - 1
            : min(index + dataLength(ofStatus: status), data.count - 1)
        messages.append(Array(data[index...end]))
        index = end + 1
    }
    return messages
}

/// Whitespace is ignored, so a page that formats its hex with spaces still works.
public func bytes(fromHex hex: String) throws -> [UInt8] {
    let digits = try hex.utf8.filter { ![0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains($0) }.map { byte in
        guard let value = hexValue(byte) else { throw HexError.notHexadecimal }
        return value
    }
    guard digits.count.isMultiple(of: 2) else { throw HexError.oddLength }
    return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
}

/// One hex digit's value, either case; nil for anything else.
func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}

private let hexDigits = Array("0123456789ABCDEF".utf8)

/// Uppercase, no spaces: the shape the page expects for `midi.message`.
public func hex(_ bytes: [UInt8]) -> String {
    var text: [UInt8] = []
    text.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        text.append(hexDigits[Int(byte >> 4)])
        text.append(hexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: text, as: UTF8.self)
}

/// The page puts port names into its HTML, so a name with markup characters is not offered to it. Scalars, not
/// Characters: `"` plus a combining mark is one Character in Swift, yet the HTML parser still sees the quote.
public func isListablePortName(_ name: String) -> Bool {
    let markup = "<>&\"'".unicodeScalars
    return !name.unicodeScalars.contains { markup.contains($0) }
}

/// The name doubles as the UID the page remembers the device by (ADR-0005). Sorted keys keep the text reproducible.
public func endpointsJSON(_ names: [String]) -> String {
    let endpoints = names.map { ["MIDIEntityNameKey": $0, "MIDIDeviceNameKey": $0, "MIDIEndpointUIDKey": $0] }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding dictionaries of strings cannot fail.
    return String(decoding: try! encoder.encode(endpoints), as: UTF8.self)
}

private struct EndpointName: Decodable {
    let entity: String?

    private enum CodingKeys: String, CodingKey {
        case entity = "MIDIEntityNameKey"
    }
}

/// The port the page asks to open, as the JSON object it was handed from `endpointsJSON`.
public func entityName(fromEndpointJSON json: String) -> String? {
    (try? JSONDecoder().decode(EndpointName.self, from: Data(json.utf8)))?.entity
}
