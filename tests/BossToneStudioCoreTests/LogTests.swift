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

@Test func traceLineCutsEachArgumentTo120Characters() {
    let long = String(repeating: "é", count: 130)
    let line = traceLine("->", "$$cmd", [long, "short"])
    #expect(line == "[trace] -> $$cmd ['\(String(repeating: "é", count: 120))', 'short']")
}
