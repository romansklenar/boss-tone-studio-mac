// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BossToneStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BossToneStudioCore"),
        .executableTarget(name: "BossToneStudio", dependencies: ["BossToneStudioCore"]),
        // Lowercase on purpose: Python's tests/ is the same folder on a case-insensitive disk and stays until the
        // Python code goes; then this moves to the default Tests/ and `path` is dropped.
        .testTarget(
            name: "BossToneStudioCoreTests",
            dependencies: ["BossToneStudioCore"],
            path: "tests/BossToneStudioCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
