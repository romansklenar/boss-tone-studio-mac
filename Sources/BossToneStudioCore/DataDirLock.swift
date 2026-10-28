import Darwin
import Foundation

/// One process per data folder: another one's in-memory Librarian would overwrite this one's writes or an import.
/// Keep the value alive for the process's lifetime; closing its descriptor (the OS does so on exit) releases the lock.
public final class DataDirLock: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// nil when another holder has the lock, or when the file cannot be opened (logged, so the two stay apart).
    public static func acquire(_ lockFile: URL) -> DataDirLock? {
        do {
            try FileManager.default.createDirectory(
                at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            log("cannot create the folder of \(lockFile.path): \(error.localizedDescription)")
            return nil
        }
        // Not inherited by child processes, which would keep the folder locked after this one quits.
        let descriptor = lockFile.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644) } ?? -1
        }
        guard descriptor >= 0 else {
            log("cannot open \(lockFile.path): \(String(cString: strerror(errno)))")
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno != EWOULDBLOCK { log("cannot lock \(lockFile.path): \(String(cString: strerror(errno)))") }
            close(descriptor)
            return nil
        }
        return DataDirLock(descriptor: descriptor)
    }
}
