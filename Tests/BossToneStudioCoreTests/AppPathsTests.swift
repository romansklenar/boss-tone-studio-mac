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
    let checkout = URL(fileURLWithPath: "/checkout", isDirectory: true)
    func dataDir(_ env: [String: String]) -> String {
        AppPaths.dataDir(env: env, bundleResources: nil, checkout: checkout).path
    }

    #expect(AppPaths.appName == "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)")
    #expect(dataDir(["BTS_DATA_DIR": "/tmp/bts data"]) == "/tmp/bts data")
    let standard = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BOSS TONE STUDIO for KATANA MkII (Apple Silicon)").path
    #expect(dataDir([:]) == standard)
    #expect(dataDir(["BTS_DATA_DIR": ""]) == standard, "empty counts as unset")
}

@Test func relativeFoldersFollowTheCheckoutOnlyOutsideAnApp() {
    let resources = URL(fileURLWithPath: "/Applications/BTS.app/Contents/Resources", isDirectory: true)
    let workingDirectory = FileManager.default.currentDirectoryPath
    let env = ["BTS_DATA_DIR": "tmp/x", "BTS_HTML_DIR": "tmp/x"]
    func paths(bundle: URL?, checkout: URL) -> [String] {
        [
            AppPaths.dataDir(env: env, bundleResources: bundle, checkout: checkout).path,
            AppPaths.htmlDir(env: env, bundleResources: bundle, checkout: checkout).path,
        ]
    }

    let checkout = URL(fileURLWithPath: "/checkout", isDirectory: true)
    #expect(paths(bundle: nil, checkout: checkout) == ["/checkout/tmp/x", "/checkout/tmp/x"])
    #expect(paths(bundle: resources, checkout: checkout) == ["\(workingDirectory)/tmp/x", "\(workingDirectory)/tmp/x"])
    let withoutSlash = URL(fileURLWithPath: "/checkout", isDirectory: false)
    #expect(paths(bundle: nil, checkout: withoutSlash) == ["/checkout/tmp/x", "/checkout/tmp/x"])
    for bundle in [nil, resources] {
        let home = AppPaths.dataDir(env: ["BTS_DATA_DIR": "~/x"], bundleResources: bundle, checkout: checkout).path
        #expect(home == NSHomeDirectory() + "/x")
    }
}

@Test func bundleResourcesCountOnlyInsideAnApp() {
    let app = URL(fileURLWithPath: "/Applications/BTS.app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    #expect(AppPaths.bundleResources(bundleURL: app, resourceURL: resources) == resources)
    // A bare executable (`make run`) is its own bundle: its resources are the build folder, never Roland's web app.
    let build = URL(fileURLWithPath: "/checkout/.build/arm64-apple-macosx/debug", isDirectory: true)
    #expect(AppPaths.bundleResources(bundleURL: build, resourceURL: build) == nil)
}
