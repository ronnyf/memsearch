// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemSearch-CLI",
    platforms: [.macOS(.v14)],   // macOS-only per spec; iOS hosts construct programmatically
    products: [
        // Binary name `memsearch` (user-facing CLI) deliberately differs from the Swift module
        // name `MemSearchCLI`. APFS is case-insensitive, so a `memsearch` module collides with
        // the imported `MemSearch` library module when SwiftPM's test build emits both
        // `.swiftmodule` files into the same directory. Decoupling the product name from the
        // module name keeps the binary `memsearch` while letting the test target
        // `@testable import MemSearchCLI`.
        .executable(name: "memsearch", targets: ["MemSearchCLI"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Config files use JSON via Foundation — no external dep needed.
        // Future: YAML / TOML loaders plug in behind `ConfigLoader`'s
        // file-extension dispatch without touching `ResolvedConfig`.
    ],
    targets: [
        .executableTarget(
            name: "MemSearchCLI",
            dependencies: [
                .product(name: "MemSearch",                 package: "MemSearch"),
                .product(name: "MemSearchSQLite",           package: "MemSearch"),
                .product(name: "MemSearchEmbeddersHTTP",    package: "MemSearch"),
                .product(name: "ArgumentParser",            package: "swift-argument-parser"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "MemSearchCLITests",
            dependencies: ["MemSearchCLI"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
