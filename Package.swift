// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VideoContext",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VideoContextCore", targets: ["VideoContextCore"]),
        .executable(name: "VideoContext", targets: ["VideoContextApp"]),
        .executable(name: "video-context-mcp", targets: ["VideoContextMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "VideoContextCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "VideoContextMCP",
            dependencies: [
                "VideoContextCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "VideoContextApp",
            dependencies: [
                "VideoContextCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("Resources/ModelProbe.jpg")]
        ),
        .testTarget(
            name: "VideoContextCoreTests",
            dependencies: ["VideoContextCore"]
        ),
        .testTarget(
            name: "VideoContextAppTests",
            dependencies: [
                "VideoContextApp",
                "VideoContextCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
