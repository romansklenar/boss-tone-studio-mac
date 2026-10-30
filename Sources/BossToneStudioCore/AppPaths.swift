import Foundation

/// Where the app keeps its data and finds Roland's web app, as 0.1.1 chose them.
public enum AppPaths {
    /// Also the bundle's name and the data folder's: users of 0.1.x keep their Librarian.
    public static let appName = "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)"

    /// Roland's own installed app, the last place to look.
    static let rolandHTML = URL(
        fileURLWithPath: "/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app/Contents/Resources/html",
        isDirectory: true)

    /// `BTS_DATA_DIR`, else `~/Library/Application Support/<appName>`.
    public static func dataDir(env: [String: String], bundleResources: URL?, checkout: URL) -> URL {
        if let custom = folder(named: "BTS_DATA_DIR", env: env, bundleResources: bundleResources, checkout: checkout) {
            return custom
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// The resources folder of the `.app` this runs from, else nil: a bare executable (`make run`) is its own bundle,
    /// whose "resources" are the build folder, so it would name that folder in the not-found message.
    public static func bundleResources(bundleURL: URL, resourceURL: URL?) -> URL? {
        bundleURL.pathExtension == "app" ? resourceURL : nil
    }

    /// `BTS_HTML_DIR`; else the first of the bundle's `roland-html`, the checkout's `build/roland/html` and Roland's
    /// installed app that has an `index.html`, else the first of them (the caller reports it missing).
    public static func htmlDir(env: [String: String], bundleResources: URL?, checkout: URL) -> URL {
        htmlDir(env: env, bundleResources: bundleResources, checkout: checkout, installed: rolandHTML)
    }

    static func htmlDir(env: [String: String], bundleResources: URL?, checkout: URL, installed: URL) -> URL {
        if let custom = folder(named: "BTS_HTML_DIR", env: env, bundleResources: bundleResources, checkout: checkout) {
            return custom
        }
        let candidates = [
            bundleResources?.appendingPathComponent("roland-html", isDirectory: true),
            checkout.appendingPathComponent("build/roland/html", isDirectory: true),
            installed,
        ].compactMap { $0 }
        return candidates.first(where: hasIndex) ?? candidates[0]
    }

    /// The folder an environment variable names. A bare executable takes a relative one from the checkout, since Xcode
    /// runs it from DerivedData and expands no build settings in a package scheme (ADR-0013). A `.app` takes it from
    /// the working directory: `checkout` is baked in at build time and may not exist on this Mac. A leading `~` is
    /// expanded, since a scheme or `env` passes it as is and it would otherwise name a folder `~` in the checkout.
    private static func folder(named name: String, env: [String: String], bundleResources: URL?, checkout: URL) -> URL?
    {
        guard let value = env[name], !value.isEmpty else { return nil }
        let custom = (value as NSString).expandingTildeInPath
        guard bundleResources == nil else { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = URL(fileURLWithPath: checkout.path, isDirectory: true)
        return URL(fileURLWithPath: custom, isDirectory: true, relativeTo: base).absoluteURL
    }

    public static func hasIndex(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let index = folder.appendingPathComponent("index.html").path
        return FileManager.default.fileExists(atPath: index, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
