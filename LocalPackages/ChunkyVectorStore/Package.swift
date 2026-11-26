// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ChunkyVectorStore",
    products: [
        .library(name: "ChunkyVectorStore", targets: ["ChunkyVectorStore"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.4"),
    ],
    targets: [
        .target(
            name: "ChunkyVectorStore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "ChunkyVectorStoreTests", dependencies: ["ChunkyVectorStore"]),
    ]
)
