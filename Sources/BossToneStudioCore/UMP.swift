/// MIDI 1.0 messages as Universal MIDI Packets (MIDI 1.0 protocol), the format of CoreMIDI's event lists.
///
/// One packet (UMP) per element: channel voice and system messages are one word, SysEx goes out as SysEx7 packets of
/// two words with up to six payload bytes each. A SysEx that has no closing F7 is closed all the same: UMP cannot
/// leave one open at the end of a message.
public func umpPackets(for message: [UInt8], group: UInt8 = 0) -> [[UInt32]] {
    guard let status = message.first, status >= 0x80, status != 0xF7 else { return [] }
    let group = UInt32(group & 0x0F) << 24
    if status == 0xF0 {
        return sysExPackets(message.dropFirst(), group: group)
    }
    let length = dataLength(ofStatus: status)
    let data1 = length >= 1 && message.count > 1 ? UInt32(message[1]) : 0
    let data2 = length >= 2 && message.count > 2 ? UInt32(message[2]) : 0
    let type: UInt32 = status < 0xF0 ? 0x2 : 0x1
    return [[type << 28 | group | UInt32(status) << 16 | data1 << 8 | data2]]
}

private func sysExPackets(_ message: ArraySlice<UInt8>, group: UInt32) -> [[UInt32]] {
    let payload = message.last == 0xF7 ? message.dropLast() : message
    let count = max(1, (payload.count + 5) / 6)  // F0 F7 is one empty packet
    return (0..<count).map { packet in
        let start = payload.startIndex + packet * 6
        let chunk = payload[start..<min(start + 6, payload.endIndex)]
        var bytes = [UInt32](repeating: 0, count: 6)
        for (index, byte) in chunk.enumerated() {
            bytes[index] = UInt32(byte)
        }
        let status: UInt32 = count == 1 ? 0 : packet == 0 ? 1 : packet == count - 1 ? 3 : 2
        let header: UInt32 = 0x3 << 28 | group | status << 20 | UInt32(chunk.count) << 16
        return [header | bytes[0] << 8 | bytes[1], bytes[2] << 24 | bytes[3] << 16 | bytes[4] << 8 | bytes[5]]
    }
}

/// Turns incoming packets back into whole MIDI 1.0 messages. Words may arrive in any slices: a packet cut off at
/// the end of one `feed` is completed by the next, and so is a SysEx.
public struct UMPReassembler: Sendable {
    /// F0 and F7 included. An All Data Backup is about 81 KB; a device sending without end must not fill the memory.
    static let maxSysExBytes = 1_048_576

    private var unread: [UInt32] = []
    private var sysEx: [UInt8]?
    private let output: @Sendable (String) -> Void

    public init() {
        self.init { print($0) }
    }

    /// `output` prints one log line.
    init(output: @escaping @Sendable (String) -> Void) {
        self.output = output
    }

    /// MIDI time code quarter frames (`F1`), clock (`F8`) and active sensing (`FE`) are dropped, as 0.1.1's
    /// `ignore_types(timing=True, active_sense=True)` dropped them; so are message types and packets this app has no
    /// use for, and a SysEx longer than `maxSysExBytes` (logged once).
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
        // F0 and F7 are SysEx's own packets, never system messages here; F1, F8 and FE are dropped (see `feed`).
        return status < 0xF1 || [0xF1, 0xF7, 0xF8, 0xFE].contains(status) ? nil : message(word)
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
            if let count = sysEx?.count, count + 1 > Self.maxSysExBytes { dropLongSysEx() }  // F7 is still to come
        case 3:
            guard let start = sysEx else { return nil }
            sysEx = nil
            guard start.count + payload.count + 1 <= Self.maxSysExBytes else {
                dropLongSysEx()
                return nil
            }
            return start + payload + [0xF7]
        default:
            break
        }
        return nil
    }

    /// Its later packets find no SysEx to continue, so they are dropped without another line.
    private mutating func dropLongSysEx() {
        sysEx = nil
        output("[bts] dropped an incoming SysEx longer than \(Self.maxSysExBytes) bytes")
    }
}
