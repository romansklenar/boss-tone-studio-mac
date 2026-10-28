import Darwin
import Foundation
import os

/// The text is the Python bridge's. It carries a path the page chose, so a caller logs it through `escaped`.
public struct FileAccessError: Error, Equatable, LocalizedError {
    public let message: String

    public var errorDescription: String? { message }
}

/// Which files the page may reach (`doc/bridge-protocol.md`, rule 4): the app's data and temp folders, plus exactly
/// what the user picked in a file dialog. A picked file to open is readable only; a picked path to save is both, since
/// the page writes a backup and may read it back. Dialog results arrive on the main thread and commands on connection
/// queues, so the picked paths sit behind a lock.
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

    /// The canonical file to read; the caller must use the returned URL, not the path it passed in.
    public func checkRead(_ path: String) throws -> URL {
        guard let canonical = Self.canonical(path),
            inAppFolder(canonical) || picked.withLock({ $0.opened.contains(canonical) || $0.saved.contains(canonical) })
        else { throw FileAccessError(message: "\(path) was not chosen in a file dialog") }
        return URL(fileURLWithPath: canonical)
    }

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
            return canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The path with `..` and links resolved, as Python's `Path.resolve()` gave it, so a link cannot lead out of a
    /// folder and `/var` and `/private/var` are one place. A file that does not exist yet (a save target) is its
    /// resolved parent plus its name; with no parent either, the standardised path stands. nil: a path no file
    /// system call would read as typed (a NUL byte), or a link that leads nowhere (writing through it would create
    /// its target).
    static func canonical(_ path: String) -> String? {
        guard !path.utf8.contains(0) else { return nil }
        let standardised = URL(fileURLWithPath: path).standardizedFileURL
        if let resolved = realPath(standardised.path) { return resolved }
        var info = stat()
        guard lstat(standardised.path, &info) != 0 else { return nil }
        guard let parent = realPath(standardised.deletingLastPathComponent().path) else { return standardised.path }
        return URL(fileURLWithPath: parent).appendingPathComponent(standardised.lastPathComponent).path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
