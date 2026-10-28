/// MIDI 1.0 messages as Universal MIDI Packets (MIDI 1.0 protocol), the format of CoreMIDI's event lists.
///
/// Channel voice and system messages are one word, SysEx goes out as SysEx7 packets of up to six payload bytes. A
/// SysEx that has no closing F7 is closed all the same: UMP cannot leave one open at the end of a message.
public func umpWords(for message: [UInt8], group: UInt8 = 0) -> [UInt32] {
    guard let status = message.first, status >= 0x80, status != 0xF7 else { return [] }
    let group = UInt32(group & 0x0F) << 24
    if status == 0xF0 {
        return sysExWords(message.dropFirst(), group: group)
    }
    let length = dataLength(ofStatus: status)
    let data1 = length >= 1 && message.count > 1 ? UInt32(message[1]) : 0
    let data2 = length >= 2 && message.count > 2 ? UInt32(message[2]) : 0
    let type: UInt32 = status < 0xF0 ? 0x2 : 0x1
    return [type << 28 | group | UInt32(status) << 16 | data1 << 8 | data2]
}

private func sysExWords(_ message: ArraySlice<UInt8>, group: UInt32) -> [UInt32] {
    let payload = message.last == 0xF7 ? message.dropLast() : message
    let packets = max(1, (payload.count + 5) / 6)  // F0 F7 is one empty packet
    var words: [UInt32] = []
    words.reserveCapacity(packets * 2)
    for packet in 0..<packets {
        let start = payload.startIndex + packet * 6
        let chunk = payload[start..<min(start + 6, payload.endIndex)]
        var bytes = [UInt32](repeating: 0, count: 6)
        for (index, byte) in chunk.enumerated() {
            bytes[index] = UInt32(byte)
        }
        let status: UInt32 = packets == 1 ? 0 : packet == 0 ? 1 : packet == packets - 1 ? 3 : 2
        let header: UInt32 = 0x3 << 28 | group | status << 20 | UInt32(chunk.count) << 16
        words.append(header | bytes[0] << 8 | bytes[1])
        words.append(bytes[2] << 24 | bytes[3] << 16 | bytes[4] << 8 | bytes[5])
    }
    return words
}

/// Turns incoming packets back into whole MIDI 1.0 messages. Words may arrive in any slices: a packet cut off at
/// the end of one `feed` is completed by the next, and so is a SysEx.
public struct UMPReassembler: Sendable {
    private var unread: [UInt32] = []
    private var sysEx: [UInt8]?

    public init() {}

    /// Clock (`F8`) and active sensing (`FE`) are dropped, as are message types and packets this app has no use for.
    public mutating func feed(_ words: [UInt32]) -> [[UInt8]] {
        let words = unread + words
        unread = []
        var messages: [[UInt8]] = []
        var index = 0
        while index < words.count {
            let first = words[index]
            let size = Self.wordCount(messageType: first >> 28)
            guard index + size <= words.count else {
                unread = Array(words[index...])
                break
            }
            let message: [UInt8]? =
                switch first >> 28 {
                case 0x1: Self.systemMessage(first)
                case 0x2: Self.channelMessage(first)
                case 0x3: sysExPacket(first, words[index + 1])
                default: nil
                }
            if let message {
                messages.append(message)
            }
            index += size
        }
        return messages
    }

    private static func wordCount(messageType: UInt32) -> Int {
        switch messageType {
        case 0x3, 0x4, 0x8...0xA: 2
        case 0xB, 0xC: 3
        case 0x5, 0xD...0xF: 4
        default: 1  // 0x0...0x2, 0x6, 0x7
        }
    }

    private static func message(_ word: UInt32) -> [UInt8] {
        let status = UInt8(truncatingIfNeeded: word >> 16)
        let data = [UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        return [status] + data.prefix(dataLength(ofStatus: status))
    }

    private static func channelMessage(_ word: UInt32) -> [UInt8]? {
        (0x80...0xEF).contains((word >> 16) & 0xFF) ? message(word) : nil
    }

    private static func systemMessage(_ word: UInt32) -> [UInt8]? {
        let status = (word >> 16) & 0xFF
        // F0 and F7 are SysEx's own packets, never system messages here.
        return status < 0xF1 || [0xF7, 0xF8, 0xFE].contains(status) ? nil : message(word)
    }

    private mutating func sysExPacket(_ first: UInt32, _ second: UInt32) -> [UInt8]? {
        let count = min(Int((first >> 16) & 0xF), 6)
        let payload = [first >> 8, first, second >> 24, second >> 16, second >> 8, second]
            .prefix(count).map { UInt8(truncatingIfNeeded: $0) }
        switch (first >> 20) & 0xF {
        case 0:
            sysEx = nil
            return [0xF0] + payload + [0xF7]
        case 1:
            sysEx = [0xF0] + payload
        case 2:
            sysEx?.append(contentsOf: payload)
        case 3:
            guard let start = sysEx else { return nil }
            sysEx = nil
            return start + payload + [0xF7]
        default:
            break
        }
        return nil
    }
}
