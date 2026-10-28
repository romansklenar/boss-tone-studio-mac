import Darwin
import Foundation

public enum StorageError: Error, Equatable, LocalizedError {
    case invalidKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key): "invalid storage key \(escaped(key))"
        }
    }
}

/// A crash mid-write must not truncate a file such as ID_LIST, which would make the whole Librarian look empty.
public func writeAtomically(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

/// nil when the path is not a regular file, as Python's `is_file()` (which follows links) says, or not valid UTF-8.
public func readText(_ url: URL) -> String? {
    var info = stat()
    let found = url.withUnsafeFileSystemRepresentation { path in
        path.map { stat($0, &info) == 0 } ?? false
    }
    guard found, info.st_mode & S_IFMT == S_IFREG, let data = try? Data(contentsOf: url) else { return nil }
    // Not `String(data:encoding:)`, which drops a leading BOM; invalid bytes come back as U+FFFD and fail the compare.
    let text = String(decoding: data, as: UTF8.self)
    return text.utf8.elementsEqual(data) ? text : nil
}

/// The page's `app.storage2`: one file per key, shared by the bridge and the Librarian import.
public struct Storage2: Sendable {
    public let directory: URL

    public init(dataDir: URL) throws {
        directory = dataDir.appendingPathComponent("storage2")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func read(_ key: String) throws -> String? {
        readText(try url(for: key))
    }

    /// An empty value deletes the key, as the page expects.
    public func write(_ key: String, _ value: String) throws {
        let file = try url(for: key)
        if value.isEmpty {
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            }
        } else {
            try writeAtomically(value, to: file)
        }
    }

    /// Python's `urllib.parse.quote(key, safe="")`, so folders written by 0.1.1 read back and no key can name a path.
    public static func fileName(for key: String) throws -> String {
        var name = ""
        for byte in key.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                UInt8(ascii: "~"):
                name.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                name += "%" + (byte < 0x10 ? "0" : "") + String(byte, radix: 16, uppercase: true)
            }
        }
        // `.` and `..` survive quoting and would name the folder itself or its parent.
        if ["", ".", ".."].contains(name) { throw StorageError.invalidKey(key) }
        return name
    }

    private func url(for key: String) throws -> URL {
        directory.appendingPathComponent(try Self.fileName(for: key))
    }
}
