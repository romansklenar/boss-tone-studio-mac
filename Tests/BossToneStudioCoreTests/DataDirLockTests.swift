import Foundation
import Testing

@testable import BossToneStudioCore

@Test func theFolderIsLockedUntilItsHolderCloses() throws {
    try withTemporaryFolder { folder in
        let lockFile = folder.appendingPathComponent("data/app.lock")  // `data` does not exist yet
        var first = DataDirLock.acquire(lockFile)
        #expect(first != nil)
        #expect(DataDirLock.acquire(lockFile) == nil)
        first = nil
        #expect(DataDirLock.acquire(lockFile) != nil)
    }
}

@Test func aLockFileThatCannotBeCreatedIsNotAnAcquiredLock() throws {
    try withTemporaryFolder { folder in
        let file = folder.appendingPathComponent("file")
        try writeAtomically("", to: file)
        #expect(DataDirLock.acquire(file.appendingPathComponent("data/app.lock")) == nil)
    }
}
