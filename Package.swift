// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleBox",
    platforms: [
        .macOS(.v13)
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
            path: "Sources/AppleBox"
        ),
        .testTarget(
            name: "AppleBoxTests",
            dependencies: [
                "AppleBox",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/AppleBoxTests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
