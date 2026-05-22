// swift-tools-version: 6.0
import PackageDescription

let phase1Settings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "MemSearch",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "MemSearch",                 targets: ["MemSearch"]),
        .library(name: "MemSearchSQLite",           targets: ["MemSearchSQLite"]),
        .library(name: "MemSearchEmbeddersHTTP",    targets: ["MemSearchEmbeddersHTTP"]),
        .library(name: "SQLiteVec",                 targets: ["SQLiteVec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // --- C wrapper for sqlite-vec (vendored, static-link).
        .target(
            name: "SQLiteVec",
            path: "Sources/SQLiteVec",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .unsafeFlags(["-w"]),    // suppress 123 upstream warnings (Spike 0a note)
            ]
        ),

        // --- Library: engine + types + protocols + chunker + RRF + mocks.
        .target(
            name: "MemSearch",
            swiftSettings: phase1Settings
        ),

        // --- Library: SQLite-backed VectorStore.
        .target(
            name: "MemSearchSQLite",
            dependencies: [
                "MemSearch",
                "SQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: phase1Settings
        ),

        // --- Library: HTTP embedders. Phase 1 ships OpenAIEmbedder only.
        .target(
            name: "MemSearchEmbeddersHTTP",
            dependencies: ["MemSearch"],
            swiftSettings: phase1Settings
        ),

        // --- Tests.
        .testTarget(
            name: "MemSearchTests",
            dependencies: ["MemSearch"],
            swiftSettings: phase1Settings
        ),
        .testTarget(
            name: "MemSearchSQLiteTests",
            dependencies: ["MemSearch", "MemSearchSQLite"],
            swiftSettings: phase1Settings
        ),
        .testTarget(
            name: "MemSearchEmbeddersHTTPTests",
            dependencies: ["MemSearch", "MemSearchEmbeddersHTTP"],
            swiftSettings: phase1Settings
        ),
    ],
    swiftLanguageModes: [.v6]
)
