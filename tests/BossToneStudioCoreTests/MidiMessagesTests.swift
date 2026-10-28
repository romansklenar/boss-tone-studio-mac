import Foundation
import Testing

@testable import BossToneStudioCore

private func split(_ hexString: String) throws -> [String] {
    try splitMessages(bytes(fromHex: hexString)).map(hex)
}

@Test func wholeMessagesAreKeptApart() throws {
    let messages = try split("F041100000003312600006570340F7C005903C64F8")
    #expect(messages == ["F041100000003312600006570340F7", "C005", "903C64", "F8"])
}

@Test func strayDataBytesAreDropped() throws {
    #expect(try split("7FC005") == ["C005"])
}

@Test func unterminatedSysExRunsToTheEnd() throws {
    #expect(try split("F0410000") == ["F0410000"])
}

@Test func aChannelMessageCutOffByTheEndIsKeptAsFarAsItGoes() throws {
    #expect(try split("903C") == ["903C"])
    #expect(try split("B0") == ["B0"])
    #expect(try split("") == [])
}

@Test func systemCommonMessagesTakeTheirDataBytes() throws {
    #expect(try split("F105F23F7DF304F6F7") == ["F105", "F23F7D", "F304", "F6", "F7"])
}

@Test func portNamesWithMarkupAreNotListed() {
    #expect(isListablePortName("KATANA"))
    #expect(isListablePortName("KATANA DAW CTRL"))
    #expect(!isListablePortName("<img src=x>"))
    #expect(!isListablePortName("A&B"))
    #expect(!isListablePortName("say \"hi\""))
    #expect(!isListablePortName("it's"))
    #expect(!isListablePortName("a>b"))
}

@Test func endpointsCarryTheNameAsUID() throws {
    let json = endpointsJSON(["KATANA", "KATANA DAW CTRL"])
    let endpoints = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
    #expect(endpoints.count == 2)
    for (endpoint, name) in zip(endpoints, ["KATANA", "KATANA DAW CTRL"]) {
        #expect(endpoint == ["MIDIEntityNameKey": name, "MIDIDeviceNameKey": name, "MIDIEndpointUIDKey": name])
    }
}

@Test func endpointsJSONIsDeterministic() {
    #expect(
        endpointsJSON(["KATANA"])
            == #"[{"MIDIDeviceNameKey":"KATANA","MIDIEndpointUIDKey":"KATANA","MIDIEntityNameKey":"KATANA"}]"#)
    #expect(endpointsJSON([]) == "[]")
}

@Test func entityNameIsReadFromTheEndpointTheNamePageSendsBack() {
    #expect(entityName(fromEndpointJSON: #"{"MIDIEntityNameKey": "KATANA", "MIDIDeviceNameKey": "x"}"#) == "KATANA")
    #expect(entityName(fromEndpointJSON: #"{"MIDIEntityNameKey":"Gerät é"}"#) == "Gerät é")
    // The page sends back what endpointsJSON gave it, one element at a time.
    let element = endpointsJSON(["KATANA DAW CTRL"]).dropFirst().dropLast()
    #expect(entityName(fromEndpointJSON: String(element)) == "KATANA DAW CTRL")
}

@Test func entityNameIsNilWhenThereIsNoUsableName() {
    for json in ["", "not json", "[]", "{}", #"{"MIDIEntityNameKey": 3}"#, #"{"MIDIEntityNameKey": null}"#, "null"] {
        #expect(entityName(fromEndpointJSON: json) == nil, "\(json)")
    }
}

@Test func hexRoundTripsAndRejectsGarbage() throws {
    #expect(try bytes(fromHex: "f07e") == [0xF0, 0x7E])
    #expect(hex([0xF0, 0x7E]) == "F07E")
    #expect(hex([]) == "")
    #expect(try bytes(fromHex: "") == [])
    #expect(try bytes(fromHex: " F0 7e\n00\t") == [0xF0, 0x7E, 0x00])
    #expect(throws: HexError.notHexadecimal) { try bytes(fromHex: "F0Z") }
    #expect(throws: HexError.notHexadecimal) { try bytes(fromHex: "\u{0663}\u{0663}") }  // non-ASCII digits
    #expect(throws: HexError.oddLength) { try bytes(fromHex: "F07") }
}
