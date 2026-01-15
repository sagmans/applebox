// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleBox",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "AppleBox", targets: ["AppleBox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppleBox",
            path: "Sources/AppleBox",
            swiftSettings: [
                .swiftLanguageMode(.v5)
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
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
