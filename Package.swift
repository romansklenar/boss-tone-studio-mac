// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BossToneStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BossToneStudioCore"),
        .executableTarget(name: "BossToneStudio", dependencies: ["BossToneStudioCore"]),
        .testTarget(name: "BossToneStudioCoreTests", dependencies: ["BossToneStudioCore"]),
    ],
    swiftLanguageModes: [.v6]
)
