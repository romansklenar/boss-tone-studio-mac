import Testing
import os

@testable import BossToneStudioCore

private func roundTrip(_ message: [UInt8], group: UInt8 = 0) -> [[UInt8]] {
    var reassembler = UMPReassembler()
    return reassembler.feed(umpWords(for: message, group: group))
}

/// A SysEx whose payload is 0, 1, 2, … so a wrong byte shows up in the comparison.
private func sysEx(payloadCount: Int) -> [UInt8] {
    [0xF0] + (0..<payloadCount).map { UInt8($0 % 128) } + [0xF7]
}

/// The SysEx7 status nibble (0 complete, 1 start, 2 continue, 3 end) of each packet.
private func sysExStatuses(_ words: [UInt32]) -> [UInt32] {
    stride(from: 0, to: words.count, by: 2).map { (words[$0] >> 20) & 0xF }
}

@Test func channelVoiceRoundTrips() {
    #expect(umpWords(for: [0xB0, 7, 100]) == [0x20B0_0764])
    #expect(umpWords(for: [0xC0, 5]) == [0x20C0_0500])
    for message: [UInt8] in [[0xB0, 7, 100], [0xC0, 5], [0x90, 60, 1], [0xDF, 9], [0xE3, 0, 64], [0x80, 60, 0]] {
        #expect(roundTrip(message) == [message])
    }
}

@Test func theGroupGoesIntoTheHighNibbleOfTheFirstByte() {
    #expect(umpWords(for: [0x90, 60, 1], group: 2) == [0x2290_3C01])
    #expect(umpWords(for: [0x90, 60, 1], group: 0x1F) == [0x2F90_3C01])
    #expect(roundTrip([0x90, 60, 1], group: 5) == [[0x90, 60, 1]])
    #expect(umpWords(for: sysEx(payloadCount: 2), group: 3)[0] >> 24 == 0x33)
}

@Test func systemMessagesRoundTrip() {
    #expect(umpWords(for: [0xF1, 5]) == [0x10F1_0500])
    #expect(umpWords(for: [0xF2, 0x10, 0x20]) == [0x10F2_1020])
    #expect(umpWords(for: [0xF3, 4]) == [0x10F3_0400])
    #expect(umpWords(for: [0xF6]) == [0x10F6_0000])
    for message: [UInt8] in [[0xF2, 0x10, 0x20], [0xF3, 4], [0xF6], [0xFA], [0xFB], [0xFC], [0xFF]] {
        #expect(roundTrip(message) == [message])
    }
}

@Test func dataBytesBeyondTheMessageLengthAreNotCarried() {
    #expect(umpWords(for: [0xC0, 5, 99]) == [0x20C0_0500])
    #expect(umpWords(for: [0xF8, 1, 2]) == [0x10F8_0000])
}

@Test func incompleteOrUnconvertibleMessagesProduceNoWords() {
    #expect(umpWords(for: []) == [])
    #expect(umpWords(for: [0x40]) == [])
    #expect(umpWords(for: [0xF7]) == [])
}

@Test func aCutOffChannelMessageIsPaddedWithZeros() {
    #expect(umpWords(for: [0x90, 60]) == [0x2090_3C00])
    #expect(umpWords(for: [0xB0]) == [0x20B0_0000])
}

@Test func shortSysExIsOneCompletePacket() {
    #expect(umpWords(for: [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]) == [0x3004_7E00, 0x0601_0000])
    #expect(roundTrip([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]) == [[0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]])
}

@Test func emptySysExIsOneEmptyCompletePacket() {
    #expect(umpWords(for: [0xF0, 0xF7]) == [0x3000_0000, 0])
    #expect(roundTrip([0xF0, 0xF7]) == [[0xF0, 0xF7]])
}

@Test func longSysExUsesStartContinueEnd() {
    let message = sysEx(payloadCount: 15)
    let words = umpWords(for: message)
    #expect(words == [0x3016_0001, 0x0203_0405, 0x3026_0607, 0x0809_0A0B, 0x3033_0C0D, 0x0E00_0000])
    #expect(roundTrip(message) == [message])
}

@Test func sysExPacketBoundariesFollowTheSixByteChunks() {
    let cases: [(payload: Int, statuses: [UInt32], counts: [UInt32])] = [
        (0, [0], [0]), (1, [0], [1]), (6, [0], [6]), (7, [1, 3], [6, 1]),
        (12, [1, 3], [6, 6]), (13, [1, 2, 3], [6, 6, 1]), (18, [1, 2, 3], [6, 6, 6]),
    ]
    for (payload, statuses, counts) in cases {
        let message = sysEx(payloadCount: payload)
        let words = umpWords(for: message)
        #expect(sysExStatuses(words) == statuses, "payload \(payload)")
        #expect(stride(from: 0, to: words.count, by: 2).map { (words[$0] >> 16) & 0xF } == counts, "payload \(payload)")
        #expect(roundTrip(message) == [message], "payload \(payload)")
    }
}

@Test func anUnterminatedSysExIsClosedByTheEndOfItsLastPacket() {
    // UMP has no way to leave a SysEx open at the end of a message, so the receiver sees the missing F7.
    #expect(roundTrip([0xF0, 0x41, 0x00, 0x00]) == [[0xF0, 0x41, 0x00, 0x00, 0xF7]])
}

@Test func sysExSplitAcrossFeedsIsReassembledOnce() {
    let message = sysEx(payloadCount: 998)
    #expect(message.count == 1000)
    let words = umpWords(for: message)
    // 334 words cut at 111 and 222: the cuts fall inside a packet.
    let slices = [
        words[0..<(words.count / 3)], words[(words.count / 3)..<(2 * words.count / 3)], words[(2 * words.count / 3)...],
    ]
    var reassembler = UMPReassembler()
    var messages: [[UInt8]] = []
    for slice in slices {
        messages += reassembler.feed(Array(slice))
    }
    #expect(messages == [message])
}

@Test func aPacketFedOneWordAtATimeIsDecodedWhenItsLastWordArrives() {
    var reassembler = UMPReassembler()
    let words = umpWords(for: [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7])
    #expect(reassembler.feed([words[0]]) == [])
    #expect(reassembler.feed([words[1]]) == [[0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]])
    #expect(reassembler.feed([]) == [])
}

@Test func messagesInsideASysExAreYieldedBeforeIt() {
    let message = sysEx(payloadCount: 10)
    let words = umpWords(for: message)
    var reassembler = UMPReassembler()
    #expect(
        reassembler.feed(Array(words[0..<2]) + umpWords(for: [0x90, 60, 1]) + Array(words[2...])) == [
            [0x90, 60, 1], message,
        ])
}

@Test func sysExPacketsWithoutAStartAreDropped() {
    let words = umpWords(for: sysEx(payloadCount: 14))  // start, continue, end
    var reassembler = UMPReassembler()
    #expect(reassembler.feed(Array(words[2...])) == [])
    // The dropped tail leaves nothing behind: the next whole message is unaffected.
    #expect(reassembler.feed(umpWords(for: [0xF0, 0x01, 0xF7])) == [[0xF0, 0x01, 0xF7]])
}

@Test func aNewSysExStartDropsAnUnfinishedOne() {
    let first = umpWords(for: sysEx(payloadCount: 10))
    let second = umpWords(for: sysEx(payloadCount: 9))
    var reassembler = UMPReassembler()
    #expect(reassembler.feed(Array(first[0..<2]) + second) == [sysEx(payloadCount: 9)])
}

@Test func timeCodeClockAndActiveSensingAreDropped() {
    // As 0.1.1's `ignore_types(timing=True, active_sense=True)` dropped them.
    var reassembler = UMPReassembler()
    #expect(reassembler.feed(umpWords(for: [0xF1, 5])) == [])
    #expect(reassembler.feed(umpWords(for: [0xF8])) == [])
    #expect(reassembler.feed(umpWords(for: [0xFE])) == [])
    let dropped = umpWords(for: [0xF1, 5]) + umpWords(for: [0xF8]) + umpWords(for: [0xFE])
    #expect(reassembler.feed(dropped + umpWords(for: [0x90, 60, 1])) == [[0x90, 60, 1]])
}

@Test func aSysExOfUpTo1MiBIsReassembledAndALongerOneDroppedWithOneLogLine() {
    let lines = OSAllocatedUnfairLock(initialState: [String]())
    var reassembler = UMPReassembler { line in lines.withLock { $0.append(line) } }
    let largest = sysEx(payloadCount: 1_048_576 - 2)  // F0 and F7 count
    #expect(reassembler.feed(umpWords(for: largest)) == [largest])
    #expect(lines.withLock { $0 } == [])

    // Over by one byte at the end packet, and by many in the middle: each is dropped once, logged once.
    for payloadCount in [1_048_576 - 1, 1_100_000] {
        lines.withLock { $0.removeAll() }
        #expect(reassembler.feed(umpWords(for: sysEx(payloadCount: payloadCount))) == [], "\(payloadCount)")
        #expect(lines.withLock { $0 } == ["[bts] dropped an incoming SysEx longer than 1048576 bytes"])
    }
    // Nothing of the dropped one is left behind.
    #expect(reassembler.feed(umpWords(for: [0xF0, 0x01, 0xF7])) == [[0xF0, 0x01, 0xF7]])
}

@Test func otherMessageTypesAreSkippedBySize() {
    let note: [UInt32] = [0x2090_3C01]
    // A filler that would decode as a note if the size of its message type were wrong.
    let filler = note[0]
    let sizes: [(type: UInt32, words: Int)] = [
        (0x0, 1), (0x4, 2), (0x5, 4), (0x6, 1), (0x7, 1), (0x8, 2), (0x9, 2), (0xA, 2), (0xB, 3), (0xC, 3),
        (0xD, 4), (0xE, 4), (0xF, 4),
    ]
    for (type, count) in sizes {
        var reassembler = UMPReassembler()
        let skipped = [type << 28] + [UInt32](repeating: filler, count: count - 1)
        #expect(reassembler.feed(skipped + note) == [[0x90, 60, 1]], "message type \(type)")
    }
}

@Test func malformedChannelAndSystemWordsAreDropped() {
    var reassembler = UMPReassembler()
    // Status below 0x80 or above 0xEF in a channel voice word; F0 and F7 in a system word.
    let junk: [UInt32] = [0x2040_3C01, 0x20F0_0000, 0x1000_0000, 0x10F0_0000, 0x10F7_0000, 0x1090_3C01]
    #expect(reassembler.feed(junk + [0x2090_3C01]) == [[0x90, 60, 1]])
}
