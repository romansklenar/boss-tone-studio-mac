import Foundation
import Testing

@testable import BossToneStudioCore

@Test func theFolderIsLockedUntilItsHolderCloses() throws {
    try withTemporaryFolder { folder in
        let lockFile = folder.appendingPathComponent("data/app.lock")  // `data` does not exist yet
        var first = try DataDirLock.acquire(lockFile)
        #expect(first != nil)
        #expect(try DataDirLock.acquire(lockFile) == nil)
        first = nil
        #expect(try DataDirLock.acquire(lockFile) != nil)
    }
}

@Test func aLockFileThatCannotBeCreatedIsAnErrorNotAnotherHolder() throws {
    try withTemporaryFolder { folder in
        let file = folder.appendingPathComponent("file")
        try writeAtomically("", to: file)
        let lockFile = file.appendingPathComponent("data/app.lock")
        #expect(throws: DataDirLockError.self) { try DataDirLock.acquire(lockFile) }
        // The folder is there, the file cannot be opened.
        let readOnly = folder.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let error = #expect(throws: DataDirLockError.self) {
            try DataDirLock.acquire(readOnly.appendingPathComponent("app.lock"))
        }
        #expect(error?.description == "cannot open \(readOnly.path)/app.lock: Permission denied")
    }
}
