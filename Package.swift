// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OllamaStatsProxy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ollama-stats-proxy", targets: ["OllamaStatsProxy"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.30.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "OllamaStatsProxy",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Public")]
        ),
        .testTarget(name: "OllamaStatsProxyTests", dependencies: ["OllamaStatsProxy"]),
    ]
)
