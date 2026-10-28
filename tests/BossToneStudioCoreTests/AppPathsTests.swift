import Foundation
import Testing

@testable import BossToneStudioCore

@Test func htmlDirPrefersTheEnvironmentThenTheBundleThenTheCheckout() throws {
    try withTemporaryFolder { folder in
        let resources = folder.appendingPathComponent("Contents/Resources")
        let checkout = folder.appendingPathComponent("checkout")
        let installed = folder.appendingPathComponent("Roland.app/Contents/Resources/html")
        let bundled = resources.appendingPathComponent("roland-html")
        let fetched = checkout.appendingPathComponent("build/roland/html")
        func htmlDir(_ env: [String: String] = [:], bundle: URL? = resources) -> String {
            AppPaths.htmlDir(env: env, bundleResources: bundle, checkout: checkout, installed: installed).path
        }
        func addIndex(_ folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "<html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }

        #expect(htmlDir() == bundled.path, "none has an index.html: the first candidate")
        #expect(htmlDir(bundle: nil) == fetched.path, "run outside a bundle")
        try addIndex(installed)
        #expect(htmlDir() == installed.path)
        try addIndex(fetched)
        #expect(htmlDir() == fetched.path)
        try addIndex(bundled)
        #expect(htmlDir() == bundled.path)
        #expect(htmlDir(bundle: nil) == fetched.path)
        // As 0.1.1: a folder named on purpose is used as it is, so a wrong one fails loudly instead of being skipped.
        #expect(htmlDir(["BTS_HTML_DIR": "/no/such/html"]) == "/no/such/html")
        #expect(htmlDir(["BTS_HTML_DIR": ""]) == bundled.path, "empty counts as unset")
    }
    #expect(
        AppPaths.rolandHTML.path
            == "/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app/Contents/Resources/html")
}

@Test func dataDirHonoursBTSDataDir() {
    #expect(AppPaths.appName == "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)")
    #expect(AppPaths.dataDir(env: ["BTS_DATA_DIR": "/tmp/bts data"]).path == "/tmp/bts data")
    let standard = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BOSS TONE STUDIO for KATANA MkII (Apple Silicon)").path
    #expect(AppPaths.dataDir(env: [:]).path == standard)
    #expect(AppPaths.dataDir(env: ["BTS_DATA_DIR": ""]).path == standard, "empty counts as unset")
}
