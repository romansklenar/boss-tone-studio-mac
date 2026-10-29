import Testing

@testable import BossToneStudioCore

@Test func pyListMatchesPythonRepr() {
    #expect(pyList([]) == "[]")
    #expect(pyList(["F07E", "1730"]) == "['F07E', '1730']")
}

@Test func escapedKeepsLogLinesSingle() {
    #expect(escaped("a\nb'c") == "'a\\nb\\'c'")
    #expect(escaped("\u{1b}[2J") == "'\\x1b[2J'")
}

@Test func escapedKeepsLogLinesInTheirOrder() {
    // Bidirectional controls, line and paragraph separators and the BOM, as Python's repr printed them.
    let controls: [Unicode.Scalar] = [
        "\u{061C}", "\u{200E}", "\u{200F}", "\u{2028}", "\u{2029}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
        "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
    ]
    for control in controls {
        let hex = String(control.value, radix: 16)
        #expect(escaped("a\(control)b") == "'a\\u\(String(repeating: "0", count: 4 - hex.count))\(hex)b'", "\(hex)")
    }
    #expect(escaped("\u{202E}gpj.exe") == "'\\u202egpj.exe'")
    #expect(escaped("é ž 日本") == "'é ž 日本'")
}

@Test func traceLineCutsEachArgumentTo120Characters() {
    let long = String(repeating: "é", count: 130)
    let line = traceLine("->", "$$cmd", [long, "short"])
    #expect(line == "[trace] -> $$cmd ['\(String(repeating: "é", count: 120))', 'short']")
}
