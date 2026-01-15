// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chunky",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Chunky",
            path: "Sources"
        )
    ]
)
