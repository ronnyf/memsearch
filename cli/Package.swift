// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemSearch-CLI",
    platforms: [.macOS(.v14)],   // macOS-only per spec; iOS hosts construct programmatically
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Config files use JSON via Foundation — no external dep needed.
        // Future: YAML / TOML loaders plug in behind `ConfigLoader`'s
        // file-extension dispatch without touching `ResolvedConfig`.
    ],
    targets: [
        .executableTarget(
            name: "memsearch",
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
            dependencies: ["memsearch"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
