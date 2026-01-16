// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChunkyTests",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .testTarget(
            name: "ChunkyTests",
            path: ".",
            exclude: ["Fixtures"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
