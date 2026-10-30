import Foundation
import Testing

@testable import BossToneStudioCore

private struct Folders {
    let access: FileAccess
    let data: URL
    let temp: URL
    let outside: URL
}

private func withFolders<T>(_ body: (Folders) throws -> T) throws -> T {
    try withTemporaryFolder { root in
        let data = root.appendingPathComponent("data")
        let temp = root.appendingPathComponent("temp")
        let outside = root.appendingPathComponent("outside")
        for folder in [data, temp, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return try body(
            Folders(access: FileAccess(dataDir: data, tempDir: temp), data: data, temp: temp, outside: outside))
    }
}

private func refusedToRead(_ path: String) -> MessageError {
    MessageError("\(path) was not chosen in a file dialog")
}

private func refusedToWrite(_ path: String) -> MessageError {
    MessageError("\(path) was not chosen in a save dialog")
}

@Test func appFoldersArePermitted() throws {
    try withFolders { folders throws in
        for folder in [folders.data, folders.temp] {
            let target = folder.appendingPathComponent("backup.alb")
            let expected = onDisk(folder.path) + "/backup.alb"
            #expect(try folders.access.checkRead(target.path).path == expected)
            #expect(try folders.access.checkWrite(target.path).path == expected)
        }
    }
}

@Test func aFileChosenInADialogIsPermitted() throws {
    try withFolders { folders throws in
        let chosen = folders.outside.appendingPathComponent("Foo.tsl")
        let other = folders.outside.appendingPathComponent("Other.tsl")
        folders.access.allowOpen(chosen.path)
        #expect(try folders.access.checkRead(chosen.path).path == onDisk(folders.outside.path) + "/Foo.tsl")
        #expect(throws: refusedToRead(other.path)) { try folders.access.checkRead(other.path) }
    }
}

@Test func otherPathsAndTraversalAreRefused() throws {
    try withFolders { folders throws in
        // More ".." than the path is deep: they stop at the root, so this is /etc/hosts whatever the temp folder is.
        let escape = folders.data.path + String(repeating: "/..", count: 20) + "/etc/hosts"
        for path in ["/etc/hosts", NSHomeDirectory() + "/x.txt", escape, "relative.txt"] {
            #expect(throws: refusedToRead(path)) { try folders.access.checkRead(path) }
            #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
        }
    }
}

@Test func aSiblingFolderSharingTheNamePrefixIsRefused() throws {
    try withFolders { folders throws in
        let sibling = folders.data.path + "-evil/backup.alb"
        try FileManager.default.createDirectory(
            atPath: folders.data.path + "-evil", withIntermediateDirectories: true)
        #expect(throws: refusedToRead(sibling)) { try folders.access.checkRead(sibling) }
        #expect(throws: refusedToWrite(sibling)) { try folders.access.checkWrite(sibling) }
    }
}

@Test func anOpenedFileIsReadOnly() throws {
    try withFolders { folders throws in
        let path = folders.outside.appendingPathComponent("Foo.tsl").path
        folders.access.allowOpen(path)
        #expect(try folders.access.checkRead(path).path == onDisk(folders.outside.path) + "/Foo.tsl")
        #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
    }
}

@Test func aSavedPathIsWritableAndReadable() throws {
    try withFolders { folders throws in
        let path = folders.outside.appendingPathComponent("Foo.tsl").path  // not on disk yet, as in a save dialog
        folders.access.allowSave(path)
        let expected = onDisk(folders.outside.path) + "/Foo.tsl"
        #expect(try folders.access.checkWrite(path).path == expected)
        #expect(try folders.access.checkRead(path).path == expected)
    }
}

@Test func pathsWithSpacesAndUnicodeArePermittedExactly() throws {
    try withFolders { folders throws in
        let name = "Foo Fighters_export ž.tsl"
        let path = folders.outside.appendingPathComponent(name).path
        let lookalike = folders.outside.appendingPathComponent("Foo Fighters_export z.tsl").path
        folders.access.allowSave(path)
        #expect(try folders.access.checkWrite(path).path == onDisk(folders.outside.path) + "/" + name)
        #expect(throws: refusedToWrite(lookalike)) { try folders.access.checkWrite(lookalike) }
    }
}

@Test func tempFolderIsReachableUnderItsSymlinkedName() throws {
    // The per-user temp folder is the real thing: /var is a symlink to /private/var, and both spellings are in use.
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0)
    let userTemp = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let temp = URL(fileURLWithPath: userTemp).appendingPathComponent("bts-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let viaPrivate = onDisk(temp.path)
    #expect(viaPrivate.hasPrefix("/private/var/"))
    let viaVar = String(viaPrivate.dropFirst("/private".count))
    let unrelated = URL(fileURLWithPath: "/nonexistent-bts-data")
    for spelling in [viaVar, viaPrivate] {
        let access = FileAccess(dataDir: unrelated, tempDir: URL(fileURLWithPath: spelling))
        for path in [viaVar + "/backup.alb", viaPrivate + "/backup.alb"] {
            #expect(try access.checkWrite(path).path == viaPrivate + "/backup.alb")
            #expect(try access.checkRead(path).path == viaPrivate + "/backup.alb")
        }
        // Folders the write will create: the symlinked part is resolved although neither level exists yet.
        let nested = try access.checkWrite(viaVar + "/newdir/sub/file.json").path
        #expect(nested == viaPrivate + "/newdir/sub/file.json")
    }
}

@Test func symlinkOutOfTheDataFolderIsRefused() throws {
    try withFolders { folders throws in
        let link = folders.data.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc")
        let path = link.path + "/hosts"
        #expect(throws: refusedToRead(path)) { try folders.access.checkRead(path) }
        #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
    }
}

@Test func symlinkOutOfTheDataFolderIsRefusedBelowFoldersThatDoNotExistYet() throws {
    try withFolders { folders throws in
        // Creating the missing folders and writing the returned URL would otherwise create files in outside/.
        let link = folders.data.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folders.outside.path)
        // Spelled from the resolved data folder, so the unresolved path does match the folder's prefix.
        let linkPath = onDisk(folders.data.path) + "/link"
        for path in [linkPath + "/sub/file.json", linkPath + "/a/b/c.json"] {
            #expect(throws: refusedToRead(path)) { try folders.access.checkRead(path) }
            #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
        }
    }
}

@Test func danglingSymlinkBelowTheDataFolderIsRefusedWhateverFollows() throws {
    try withFolders { folders throws in
        let link = folders.data.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: folders.outside.path + "/not-there-yet")
        let path = onDisk(folders.data.path) + "/dangling/sub/file"
        #expect(throws: refusedToRead(path)) { try folders.access.checkRead(path) }
        #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
    }
}

@Test func danglingSymlinkOutOfTheDataFolderIsRefused() throws {
    try withFolders { folders throws in
        // Writing through it would create the file where it points.
        let link = folders.data.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: folders.outside.path + "/not-there-yet")
        #expect(throws: refusedToWrite(link.path)) { try folders.access.checkWrite(link.path) }
        #expect(throws: refusedToRead(link.path)) { try folders.access.checkRead(link.path) }
    }
}

@Test func symlinkWithinTheDataFolderIsFollowed() throws {
    try withFolders { folders throws in
        let real = folders.data.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = folders.data.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        #expect(try folders.access.checkWrite(link.path + "/a.json").path == onDisk(real.path) + "/a.json")
    }
}

@Test func aPathWithANulByteIsRefused() throws {
    try withFolders { folders throws in
        let path = folders.data.path + "/ok.json\0.txt"  // inside the data folder but for the NUL byte
        #expect(throws: refusedToRead(path)) { try folders.access.checkRead(path) }
        #expect(throws: refusedToWrite(path)) { try folders.access.checkWrite(path) }
    }
}

@Test func aPathWhoseParentDoesNotExistEitherKeepsItsStandardisedForm() throws {
    try withFolders { folders throws in
        let chosen = "/nonexistent-bts/a/../b/Foo.tsl"
        folders.access.allowSave(chosen)
        #expect(try folders.access.checkWrite(chosen).path == "/nonexistent-bts/b/Foo.tsl")
        #expect(try folders.access.checkWrite("/nonexistent-bts/b/Foo.tsl").path == "/nonexistent-bts/b/Foo.tsl")
    }
}

@Test func aLinkSwappedInAfterTheCheckIsNotReadThrough() throws {
    try withFolders { folders throws in
        let path = folders.data.appendingPathComponent("f.txt").path
        let secret = folders.outside.appendingPathComponent("secret.txt")
        try Data("inside".utf8).write(to: URL(fileURLWithPath: path))
        try Data("secret".utf8).write(to: secret)
        let checked = try folders.access.checkRead(path)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: secret.path)
        #expect(throws: refusedToRead(path)) { try folders.access.readChecked(checked, asked: path) }
    }
}

@Test func aLinkSwappedInAfterTheCheckIsNotWrittenThrough() throws {
    try withFolders { folders throws in
        let path = folders.data.appendingPathComponent("f.txt").path
        let secret = folders.outside.appendingPathComponent("secret.txt")
        try Data("inside".utf8).write(to: URL(fileURLWithPath: path))
        try Data("secret".utf8).write(to: secret)
        let checked = try folders.access.checkWrite(path)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: secret.path)
        do {
            try folders.access.writeChecked("x", to: checked, asked: path)
            // Written: the rename replaced the link itself, never what it points to.
            let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            #expect(type == .typeRegular)
        } catch let error as MessageError {
            #expect(error == refusedToWrite(path))
        }
        #expect(try String(contentsOf: secret, encoding: .utf8) == "secret")
    }
}

@Test func aFolderSwappedForALinkAfterTheCheckIsRefused() throws {
    try withFolders { folders throws in
        let sub = folders.data.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let path = sub.appendingPathComponent("f.txt").path
        try Data("inside".utf8).write(to: URL(fileURLWithPath: path))
        let checked = try folders.access.checkWrite(path)
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(atPath: sub.path, withDestinationPath: folders.outside.path)
        #expect(throws: refusedToWrite(path)) { try folders.access.writeChecked("x", to: checked, asked: path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.outside.path).isEmpty)
    }
}

@Test func writingCreatesMissingFoldersInsideTheDataFolder() throws {
    try withFolders { folders throws in
        let path = folders.data.appendingPathComponent("new/deeper/f.txt").path
        try folders.access.writeText("x", to: path)
        #expect(try folders.access.readText(path) == "x")
    }
}

@Test func aFailedWriteLeavesTheOldFileAndNoTemporaryFile() throws {
    try withFolders { folders throws in
        let path = folders.data.appendingPathComponent("f.txt").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        // A read-only folder: the temporary file next to the target cannot be created.
        #expect(chmod(folders.data.path, 0o555) == 0)
        defer { chmod(folders.data.path, 0o755) }
        #expect(throws: (any Error).self) { try folders.access.writeText("new", to: path) }
        #expect(try folders.access.readText(path) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.data.path) == ["f.txt"])
    }
}

@Test func readingAndWritingKeepTheirAnswers() throws {
    try withFolders { folders throws in
        #expect(try folders.access.readText(folders.data.appendingPathComponent("missing.txt").path) == nil)
        let folder = folders.data.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try folders.access.readText(folder.path) == nil)
        let invalid = folders.data.appendingPathComponent("invalid.txt")
        try Data([0x41, 0xFF, 0xFE]).write(to: invalid)
        #expect(throws: StorageError.notUTF8(onDisk(invalid.path))) { try folders.access.readText(invalid.path) }
        let path = folders.data.appendingPathComponent("text.txt").path
        try folders.access.writeText("ü\n", to: path)
        #expect(try folders.access.readText(path) == "ü\n")
    }
}

@Test func aFolderHigherUpSwappedForALinkIsCaughtByWhereTheDescriptorLeads() throws {
    try withFolders { folders throws in
        // O_NOFOLLOW guards only the last name: here the file and its folder open, and F_GETPATH tells.
        let path = folders.data.appendingPathComponent("a/b/f.txt").path
        let twin = folders.outside.appendingPathComponent("a/b/f.txt")
        for file in [URL(fileURLWithPath: path), twin] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: file)
        }
        let toRead = try folders.access.checkRead(path)
        let toWrite = try folders.access.checkWrite(path)
        let a = folders.data.appendingPathComponent("a")
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(
            atPath: a.path, withDestinationPath: folders.outside.appendingPathComponent("a").path)
        #expect(throws: refusedToRead(path)) { try folders.access.readChecked(toRead, asked: path) }
        #expect(throws: refusedToWrite(path)) { try folders.access.writeChecked("x", to: toWrite, asked: path) }
        #expect(try String(contentsOf: twin, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: twin.deletingLastPathComponent().path) == ["f.txt"])
    }
}

@Test func savingOverAFileKeepsItsPermissions() throws {
    try withFolders { folders throws in
        let path = folders.data.appendingPathComponent("private.json").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        try folders.access.writeText("new", to: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try folders.access.readText(path) == "new")
    }
}
