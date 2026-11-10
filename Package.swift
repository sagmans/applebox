// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppleBox",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AppleBox", targets: ["AppleBox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "AppleBox",
            path: "Sources/AppleBox",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "AppleBoxTests",
            dependencies: [
                "AppleBox",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/AppleBoxTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // XCTestCase initializers are nonisolated, so default main-actor isolation cannot
                // apply here; test classes opt in with an explicit @MainActor instead.
            ]
        ),
    ]
)
