import Foundation
import Testing

@testable import BossToneStudioCore

/// Roland's page stores JSON.stringify(liveset), which is itself a JSON string.
private func liveset(_ name: String) -> String {
    let inner = "{\"name\": \"\(name)\", \"formatRev\": \"0002\", \"device\": \"KATANA MkII\", \"data\": [[]]}"
    return "\"" + inner.replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private struct Fixture {
    let folder: URL
    var dataDir: URL { folder.appendingPathComponent("data") }
    var storage2: URL { dataDir.appendingPathComponent("storage2") }
    var prefs: URL { folder.appendingPathComponent("roland.plist") }

    func writePrefs(_ values: [String: String]) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: prefs)
    }

    func write(_ key: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: storage2, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: storage2.appendingPathComponent(key))
    }

    func read(_ key: String) throws -> String {
        try String(contentsOf: storage2.appendingPathComponent(key), encoding: .utf8)
    }

    func exists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: storage2.appendingPathComponent(key).path)
    }

    var marker: URL { dataDir.appendingPathComponent(RolandImport.marker) }

    func ids() throws -> [Int] {
        try JSONDecoder().decode([String: [Int]].self, from: Data(read("ID_LIST").utf8))["list"] ?? []
    }
}

/// Roland's settings as 0.1.1's Python tests set them up, with the folder removed afterwards.
private func withFixture(_ body: (Fixture) throws -> Void) throws {
    try withTemporaryFolder { folder in
        let fixture = Fixture(folder: folder)
        try fixture.writePrefs([
            "ID_LIST": "{\"list\":[2,1]}",
            "1": liveset("Foo"),
            "2": liveset("Bar"),
            "0": "",
            "CONFIRM_FLAG": "true",
            "pref": "{\"guid\":\"x\"}",
        ])
        try body(fixture)
    }
}

@Test func freshLibraryMatchesRolandOrderAndValues() throws {
    try withFixture { fixture in
        try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(try fixture.ids() == [2, 1])
        #expect(try fixture.read("ID_LIST") == "{\"list\":[2,1]}")
        #expect(try fixture.read("1") == liveset("Foo"))
        #expect(try fixture.read("2") == liveset("Bar"))
        #expect(try fixture.read("CONFIRM_FLAG") == "true")
        #expect(!fixture.exists("pref"))
        #expect(!fixture.exists("0"))
    }
}

@Test func reimportAddsNothing() throws {
    try withFixture { fixture in
        try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)
        let summary = try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(summary.contains("Imported 0 livesets"))
        #expect(try fixture.ids() == [2, 1])
    }
}

@Test func collidingIdMovesToAFreeOneAndKeepsLocalLivesets() throws {
    try withFixture { fixture in
        try fixture.write("0", liveset("LIVESET 1"))
        try fixture.write("1", liveset("Mine"))
        try fixture.write("ID_LIST", "{\"list\":[0,1]}")

        try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(try fixture.ids() == [2, 3, 0, 1])
        #expect(try fixture.read("1") == liveset("Mine"))
        #expect(try fixture.read("3") == liveset("Foo"))
    }
}

@Test func stopsAtTheLibrarianLimit() throws {
    try withFixture { fixture in
        for id in 0..<49 { try fixture.write(String(id), liveset("L\(id)")) }
        try fixture.write("ID_LIST", "{\"list\":[\((0..<49).map(String.init).joined(separator: ","))]}")

        let summary = try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(try fixture.ids().count == 50)
        #expect(summary.contains("1 skipped, the Librarian holds at most 50"))
    }
}

@Test func importOnceRunsASingleTime() throws {
    try withFixture { fixture in
        RolandImport.importOnce(dataDir: fixture.dataDir, prefs: fixture.prefs)
        try fixture.writePrefs(["ID_LIST": "{\"list\":[5]}", "5": liveset("Later")])
        RolandImport.importOnce(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(try fixture.ids() == [2, 1])
        let marker = try String(contentsOf: fixture.marker, encoding: .utf8)
        #expect(marker == "Imported 2 livesets from \(fixture.prefs.path)\n")
    }
}

@Test func duplicatesInRolandsListAreImportedOnce() throws {
    try withFixture { fixture in
        try fixture.writePrefs(["ID_LIST": "{\"list\":[1,2]}", "1": liveset("Same"), "2": liveset("Same")])
        try RolandImport.importLibrarian(dataDir: fixture.dataDir, prefs: fixture.prefs)

        #expect(try fixture.ids() == [1])
    }
}

@Test func importOnceSurvivesAnUnreadablePlist() throws {
    try withFixture { fixture in
        try Data("not a plist".utf8).write(to: fixture.prefs)
        RolandImport.importOnce(dataDir: fixture.dataDir, prefs: fixture.prefs)

        let marker = try String(contentsOf: fixture.marker, encoding: .utf8)
        #expect(marker.hasPrefix("Import failed ("))
        #expect(marker.hasSuffix("); retry with `make roland-import`\n"))
        #expect(!fixture.exists("ID_LIST"))
    }
}

@Test func importOnceWaitsForRolandSettings() throws {
    try withFixture { fixture in
        let missing = fixture.folder.appendingPathComponent("missing.plist")
        RolandImport.importOnce(dataDir: fixture.dataDir, prefs: missing)

        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }
}
