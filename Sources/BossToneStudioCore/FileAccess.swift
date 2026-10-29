import Darwin
import Foundation
import os

/// The text is 0.1.1's Python bridge's. It carries a path the page chose, so a caller logs it through `escaped`.
public struct FileAccessError: Error, Equatable, LocalizedError {
    public let message: String

    public var errorDescription: String? { message }
}

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

    /// The canonical file to read. Use the returned URL, immediately and once, never the path passed in: the check
    /// holds for that URL only, and a later use of the input would resolve links again.
    public func checkRead(_ path: String) throws -> URL {
        guard let canonical = Self.canonical(path),
            inAppFolder(canonical) || picked.withLock({ $0.opened.contains(canonical) || $0.saved.contains(canonical) })
        else { throw FileAccessError(message: "\(path) was not chosen in a file dialog") }
        return URL(fileURLWithPath: canonical)
    }

    /// As `checkRead`: write to the returned URL, immediately and once.
    public func checkWrite(_ path: String) throws -> URL {
        guard let canonical = Self.canonical(path),
            inAppFolder(canonical) || picked.withLock({ $0.saved.contains(canonical) })
        else { throw FileAccessError(message: "\(path) was not chosen in a save dialog") }
        return URL(fileURLWithPath: canonical)
    }

    public func allowOpen(_ path: String) {
        guard let canonical = Self.canonical(path) else { return }
        picked.withLock { _ = $0.opened.insert(canonical) }
    }

    public func allowSave(_ path: String) {
        guard let canonical = Self.canonical(path) else { return }
        picked.withLock { _ = $0.saved.insert(canonical) }
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
