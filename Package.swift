// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ribbind",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ribbind", targets: ["Ribbind"]),
        .executable(name: "ValidationHarness", targets: ["ValidationHarness"]),
        .library(name: "RibbindKit", targets: ["RibbindKit"]),
    ],
    dependencies: [
        // KeyboardShortcuts is vendored under Sources/Vendored/KeyboardShortcuts so the
        // project builds with Command Line Tools alone (no full Xcode required).
        // Upstream: https://github.com/sindresorhus/KeyboardShortcuts (MIT, v2.4.0).
    ],
    targets: [
        .target(
            name: "KeyboardShortcuts",
            path: "Sources/Vendored/KeyboardShortcuts",
            exclude: ["LICENSE", "UPSTREAM.md"],
            resources: [
                .process("Localization"),
            ]
        ),
        .target(
            name: "RibbindKit",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/RibbindKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "Ribbind",
            dependencies: ["RibbindKit", "KeyboardShortcuts"],
            path: "Sources/Ribbind",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "ValidationHarness",
            dependencies: ["RibbindKit"]
        ),
        // XCTest is not in macOS Command Line Tools; we use the ValidationHarness
        // executable for local checks. CI (full Xcode) can re-introduce a testTarget later.
    ]
)
