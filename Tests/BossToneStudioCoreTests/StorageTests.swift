import Foundation
import Testing

@testable import BossToneStudioCore

@Test func keysAreQuotedLikePython() throws {
    #expect(try Storage2.fileName(for: "ID_LIST") == "ID_LIST")
    #expect(try Storage2.fileName(for: "0") == "0")
    #expect(try Storage2.fileName(for: "a b/ž") == "a%20b%2F%C5%BE")
    #expect(try Storage2.fileName(for: "-._~") == "-._~")
    #expect(try Storage2.fileName(for: "100%") == "100%25")
    #expect(try Storage2.fileName(for: "日本") == "%E6%97%A5%E6%9C%AC")
    #expect(try Storage2.fileName(for: "\n\u{7f}") == "%0A%7F")
    for key in ["", ".", ".."] {
        #expect(throws: StorageError.self) { try Storage2.fileName(for: key) }
    }
}

@Test func storage2ReadsWritesAndDeletes() throws {
    try withTemporaryFolder { folder in
        let storage = try Storage2(dataDir: folder)
        #expect(try storage.read("3") == nil)
        try storage.write("3", "x")
        #expect(try storage.read("3") == "x")
        try storage.write("3", "")
        #expect(try storage.read("3") == nil)
        try storage.write("3", "")  // deleting what is not there is fine
        #expect(try storage.read("3") == nil)
    }
}

@Test func storage2CreatesItsFolderAndLeavesNoTemporaryFiles() throws {
    try withTemporaryFolder { folder in
        let storage = try Storage2(dataDir: folder)
        #expect(storage.directory.lastPathComponent == "storage2")
        #expect(storage.directory.deletingLastPathComponent().path == folder.path)
        try storage.write("ID_LIST", "{\"list\":[0]}")
        try storage.write("ID_LIST", "{\"list\":[]}")
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path) == ["ID_LIST"])
    }
}

@Test func storage2RefusesKeysThatNameAFolderEvenWhenDeleting() throws {
    try withTemporaryFolder { folder in
        let storage = try Storage2(dataDir: folder)
        for key in ["", ".", ".."] {
            #expect(throws: StorageError.self) { try storage.read(key) }
            #expect(throws: StorageError.self) { try storage.write(key, "x") }
            #expect(throws: StorageError.self) { try storage.write(key, "") }
        }
        // A refused key reaches no file: nothing in the folder, and nothing next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["storage2"])
    }
}

@Test func storage2ReadsFilesTheBridgeWroteBefore() throws {
    try withTemporaryFolder { folder in
        let directory = folder.appendingPathComponent("storage2")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "a%20b%2F%C5%BE"
        try Data("Lead ž".utf8).write(to: directory.appendingPathComponent(name))
        #expect(try Storage2(dataDir: folder).read("a b/ž") == "Lead ž")
    }
}

@Test func unicodeValuesRoundTrip() throws {
    try withTemporaryFolder { folder in
        let storage = try Storage2(dataDir: folder)
        let value = "Lead ž 日本 \"q\""
        try storage.write("0", value)
        #expect(try storage.read("0") == value)
        #expect(try Data(contentsOf: storage.directory.appendingPathComponent("0")) == Data(value.utf8))
    }
}

@Test func textIsReadBackByteForByte() throws {
    try withTemporaryFolder { folder in
        let file = folder.appendingPathComponent("storage.json")
        let text = "\u{feff}{\"a\":\r\n\"b\"}\r\n\n"  // a BOM, CRLF and trailing newlines must survive
        try writeAtomically(text, to: file)
        #expect(Array(try #require(readText(file)).utf8) == Array(text.utf8))
    }
}

@Test func atomicWriteReplacesWholeFile() throws {
    try withTemporaryFolder { folder in
        let file = folder.appendingPathComponent("ID_LIST")
        try writeAtomically(String(repeating: "long ", count: 1000), to: file)
        try writeAtomically("short", to: file)
        #expect(readText(file) == "short")
        #expect(try Data(contentsOf: file) == Data("short".utf8))
    }
}

@Test func atomicWriteFailsWithoutAFolder() throws {
    try withTemporaryFolder { folder in
        let file = folder.appendingPathComponent("missing/ID_LIST")
        #expect(throws: (any Error).self) { try writeAtomically("x", to: file) }
    }
}

@Test func readTextIsNilUnlessItIsARegularFile() throws {
    try withTemporaryFolder { folder in
        #expect(readText(folder.appendingPathComponent("missing")) == nil)
        #expect(readText(folder) == nil)
        let file = folder.appendingPathComponent("file")
        try writeAtomically("text", to: file)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(readText(link) == "text")  // links followed, as 0.1.1's is_file() did
        try writeAtomically("", to: file)
        #expect(readText(file) == "")  // empty is not missing
        try Data([0xff, 0xfe, 0x41]).write(to: file)
        #expect(readText(file) == nil)  // not UTF-8
    }
}

@Test func storage2ReadThrowsInsteadOfReportingAMissingKeyWhenTheFileIsBad() throws {
    try withTemporaryFolder { folder in
        let storage = try Storage2(dataDir: folder)
        try Data([0xff, 0xfe, 0x41]).write(to: storage.directory.appendingPathComponent("ID_LIST"))
        #expect(throws: (any Error).self) { try storage.read("ID_LIST") }
        #expect(readText(storage.directory.appendingPathComponent("ID_LIST")) == nil)  // the non-throwing wrapper

        let locked = storage.directory.appendingPathComponent("0")
        try writeAtomically("liveset", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        if geteuid() != 0 {  // root reads anything
            #expect(throws: (any Error).self) { try storage.read("0") }
            #expect(readText(locked) == nil)
        }

        #expect(try storage.read("missing") == nil)  // only a missing file is "not there"
        try FileManager.default.createDirectory(
            at: storage.directory.appendingPathComponent("folder"), withIntermediateDirectories: false)
        #expect(try storage.read("folder") == nil)  // as is a non-regular file
    }
}
