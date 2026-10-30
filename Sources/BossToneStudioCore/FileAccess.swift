import Darwin
import Foundation
import os

/// Which files the page may reach (`doc/bridge-protocol.md`, rule 5): the app's data and temp folders, plus exactly
/// what the user picked in a file dialog. A picked file to open is readable only; a picked path to save is both, since
/// the page writes a backup and may read it back. Dialog results arrive on the main thread and commands in the tasks
/// that serve connections, so the picked paths sit behind a lock.
public final class FileAccess: Sendable {
    private struct Picked {
        var opened: Set<String> = []
        var saved: Set<String> = []
    }

    private let dataDir: URL
    private let tempDir: URL
    private let picked = OSAllocatedUnfairLock(initialState: Picked())

    public init(dataDir: URL, tempDir: URL) {
        self.dataDir = dataDir
        self.tempDir = tempDir
    }

    /// The canonical file to read, from the path alone: opening it by name afterwards would follow a link swapped in
    /// since. `readText` opens it without following one and checks where the descriptor leads.
    func checkRead(_ path: String) throws -> URL {
        guard let canonical = Self.canonical(path), mayRead(canonical) else { throw Self.refusedToRead(path) }
        return URL(fileURLWithPath: canonical)
    }

    /// As `checkRead`, for `writeText`.
    func checkWrite(_ path: String) throws -> URL {
        guard let canonical = Self.canonical(path), mayWrite(canonical) else { throw Self.refusedToWrite(path) }
        return URL(fileURLWithPath: canonical)
    }

    /// nil when the path is not a regular file (missing, a folder, a FIFO, a socket, a device); throws the refusal,
    /// `StorageError.notUTF8` or a `POSIXError`.
    public func readText(_ path: String) throws -> String? {
        try readChecked(checkRead(path), asked: path)
    }

    /// Creates missing parent folders, then replaces the file atomically.
    public func writeText(_ text: String, to path: String) throws {
        let file = try checkWrite(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeChecked(text, to: file, asked: path)
    }

    /// `checkRead` again on what was opened: a link swapped in for the file since then fails to open (`O_NOFOLLOW`),
    /// and one swapped in for a folder above it shows in the descriptor's path, or, when that path names another hard
    /// link of the file, as a link on the checked path. `O_NONBLOCK`, or a FIFO would wait for a writer before the
    /// check below could turn it away.
    func readChecked(_ file: URL, asked path: String) throws -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            if code == ELOOP { throw Self.refusedToRead(path) }
            // A socket or some devices refuse to open: not a file, as before reads went through a descriptor.
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { return nil }
            throw posixError(code)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        guard descriptorPath(fd).map(mayRead) == true || (mayRead(file.path) && isFile(fd, at: file.path)) else {
            throw Self.refusedToRead(path)
        }
        // `O_NONBLOCK` was for the open only: a file system that honours it for a regular file could answer EAGAIN.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw posixError(errno) }
        return try decodeUTF8(readAll(fd), at: file.path)
    }

    /// `checkWrite` again on the folder that was opened, then a temporary file created through that folder's
    /// descriptor and renamed over the target: the file's name is only ever looked up in the folder that was checked,
    /// and a link swapped in for the target is replaced, not followed.
    func writeChecked(_ text: String, to file: URL, asked path: String) throws {
        let name = file.lastPathComponent
        let folder = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw Self.refusedToWrite(path) }
            throw posixError(code)
        }
        defer { close(folder) }
        let opened = descriptorPath(folder).map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        guard
            opened.map(mayWrite) == true
                || (mayWrite(file.path) && isFile(folder, at: file.deletingLastPathComponent().path))
        else { throw Self.refusedToWrite(path) }

        // A fixed length, so a target whose name is as long as the system allows still gets one.
        let temporary = ".bts-\(UUID().uuidString).tmp"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(errno) }
        var failure: Int32 = 0
        // The rename gives the target the new file's mode: copy the old one's permission bits only. Not its owner or
        // extended attributes (Foundation's atomic write kept neither), nor setuid, setgid or sticky: new content must
        // not inherit those.
        var existing = stat()
        if fstatat(folder, name, &existing, AT_SYMLINK_NOFOLLOW) == 0, existing.st_mode & S_IFMT == S_IFREG,
            fchmod(fd, existing.st_mode & 0o777) != 0
        {
            failure = errno
        }
        if failure == 0 { failure = writeAll(Data(text.utf8), to: fd) }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure == 0, renameat(folder, temporary, folder, name) != 0 { failure = errno }
        if failure != 0 {
            unlinkat(folder, temporary, 0)
            throw posixError(failure)
        }
    }

    public func allowOpen(_ path: String) {
        guard let canonical = Self.canonical(path) else { return }
        picked.withLock { _ = $0.opened.insert(canonical) }
    }

    public func allowSave(_ path: String) {
        guard let canonical = Self.canonical(path) else { return }
        picked.withLock { _ = $0.saved.insert(canonical) }
    }

    private func mayRead(_ canonical: String) -> Bool {
        inAppFolder(canonical) || picked.withLock { $0.opened.contains(canonical) || $0.saved.contains(canonical) }
    }

    private func mayWrite(_ canonical: String) -> Bool {
        inAppFolder(canonical) || picked.withLock { $0.saved.contains(canonical) }
    }

    // 0.1.1's texts, with the path as the page sent it: callers log it through `escaped`.
    private static func refusedToRead(_ path: String) -> MessageError {
        MessageError("\(path) was not chosen in a file dialog")
    }

    private static func refusedToWrite(_ path: String) -> MessageError {
        MessageError("\(path) was not chosen in a save dialog")
    }

    /// Resolved on every check, not once: the data folder may not exist yet when this is created.
    private func inAppFolder(_ canonical: String) -> Bool {
        [dataDir, tempDir].contains { folder in
            guard let root = Self.canonical(folder.path) else { return false }
            return isInside(canonical, folder: root)
        }
    }

    /// The path with `..` and links resolved, as 0.1.1's `Path.resolve()` gave it, so a link cannot lead out of a
    /// folder and `/var` and `/private/var` are one place. What does not exist yet (a save target, folders about to be
    /// created) is the nearest existing ancestor, resolved, plus the missing names. nil: a path no file system call
    /// would read as typed (a NUL byte), or a name that exists but does not resolve, at any level (a dangling link:
    /// writing through it would create its target).
    static func canonical(_ path: String) -> String? {
        guard !path.utf8.contains(0) else { return nil }
        let standardised = URL(fileURLWithPath: path).standardizedFileURL
        let names = standardised.pathComponents.dropFirst()  // the first is "/"
        for kept in stride(from: names.count, through: 0, by: -1) {
            let ancestor = "/" + names.prefix(kept).joined(separator: "/")
            if let resolved = realPath(ancestor) {
                let missing = names.dropFirst(kept)
                return missing.reduce(URL(fileURLWithPath: resolved)) { $0.appendingPathComponent($1) }.path
            }
            // Present but unresolvable: a dangling link, a loop or no access. Not a name still to be created.
            var info = stat()
            if lstat(ancestor, &info) == 0 { return nil }
        }
        return standardised.path  // unreachable while "/" resolves
    }
}

/// Where an open descriptor leads, links resolved like `canonical`'s; nil when the system cannot say. For a file with
/// several hard links it is whichever name was looked up last, which may be one outside the allowed folders.
private func descriptorPath(_ fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Whether the descriptor is the file at `path`, reached through no link at any level: a canonical path has none, so a
/// link there was swapped in after the check.
private func isFile(_ fd: Int32, at path: String) -> Bool {
    var opened = stat()
    var named = stat()
    return fstat(fd, &opened) == 0 && fstatat(AT_FDCWD, path, &named, AT_SYMLINK_NOFOLLOW_ANY) == 0
        && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
}

private func readAll(_ fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
            return data
        } else if errno != EINTR {
            throw posixError(errno)
        }
    }
}

/// 0 when every byte was written, else the `errno`.
private func writeAll(_ data: Data, to fd: Int32) -> Int32 {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if count >= 0 {
                offset += count
            } else if errno != EINTR {
                return errno
            }
        }
        return 0
    }
}

/// `realpath`: links, `.` and `..` resolved; nil when the path does not exist.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Whether `path` lies below `folder`, both resolved: a sibling whose name only starts with the folder's is not.
func isInside(_ path: String, folder: String) -> Bool {
    path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
}
