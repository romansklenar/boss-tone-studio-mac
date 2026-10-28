import Foundation

/// Brings the Librarian (livesets with patches) over from Roland's own BOSS TONE STUDIO for KATANA MkII.
///
/// Roland's app keeps `$native.app.storage2` in its NSUserDefaults plist under the same keys the page uses here
/// (`ID_LIST`, `CONFIRM_FLAG`, one numeric key per liveset), so values are copied verbatim. The plist is only read.
public enum RolandImport {
    public static let prefs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist")
    public static let marker = "roland-librarian-imported"
    /// librarianCommonInfo.maxLivesetNum; liveset IDs live in 0..<50.
    public static let maxLivesets = 50

    /// Imports on the first launch that finds Roland's plist, so former users open straight into their library.
    public static func importOnce(dataDir: URL, prefs: URL = RolandImport.prefs) {
        let marker = dataDir.appendingPathComponent(Self.marker)
        let files = FileManager.default
        guard !files.fileExists(atPath: marker.path), files.fileExists(atPath: prefs.path) else { return }
        var summary: String
        do {
            summary = try importLibrarian(dataDir: dataDir, prefs: prefs)
        } catch {  // an unreadable plist must not keep the app from starting
            summary = "Import failed (\(error.localizedDescription)); retry with `make roland-import`"
            log(summary)
        }
        do {
            try files.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try writeAtomically(summary + "\n", to: marker)
        } catch {
            // Without the marker the import runs again on the next launch, which is harmless.
            log("Could not write \(marker.path) (\(error.localizedDescription))")
        }
    }

    /// Appends Roland's livesets to this app's Librarian; skips ones already here, so re-running is harmless.
    @discardableResult
    public static func importLibrarian(dataDir: URL, prefs: URL = RolandImport.prefs) throws -> String {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: prefs), options: [], format: nil)
        guard let roland = plist as? [String: Any] else { throw ImportError.notADictionary }
        let store = try Storage2(dataDir: dataDir)

        let ids = try idList(store.read("ID_LIST"))
        var existing = Set(try ids.compactMap { try store.read(String($0)) })
        var free = (0..<maxLivesets).filter { !ids.contains($0) }
        var imported: [Int] = []
        var skipped: [Int] = []
        for rolandID in try idList(roland["ID_LIST"] as? String) {
            guard let value = roland[String(rolandID)] as? String, !value.isEmpty, !existing.contains(value) else {
                continue
            }
            if free.isEmpty {
                skipped.append(rolandID)
                continue
            }
            let newID = free.remove(at: free.firstIndex(of: rolandID) ?? 0)
            try store.write(String(newID), value)
            existing.insert(value)
            imported.append(newID)
        }

        if !imported.isEmpty {
            // Roland's order first: that is the library the user knows; anything made here follows it.
            try store.write("ID_LIST", encode(imported + ids))
        }
        if try store.read("CONFIRM_FLAG") == nil, let flag = roland["CONFIRM_FLAG"] as? String, !flag.isEmpty {
            try store.write("CONFIRM_FLAG", flag)
        }

        var summary = "Imported \(imported.count) livesets from \(prefs.path)"
        if !skipped.isEmpty {
            summary += "; \(skipped.count) skipped, the Librarian holds at most \(maxLivesets)"
        }
        log(summary)
        return summary
    }

    private enum ImportError: Error, LocalizedError {
        case notADictionary

        var errorDescription: String? { "the settings file is not a property list dictionary" }
    }

    private struct IDList: Codable {
        var list: [Int]
    }

    private static func idList(_ json: String?) throws -> [Int] {
        guard let json, !json.isEmpty else { return [] }
        return try JSONDecoder().decode(IDList.self, from: Data(json.utf8)).list
    }

    private static func encode(_ ids: [Int]) throws -> String {
        String(decoding: try JSONEncoder().encode(IDList(list: ids)), as: UTF8.self)
    }
}
