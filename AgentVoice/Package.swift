// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentVoice", targets: ["AgentVoice"]),
    ],
    dependencies: [
        .package(path: "../GRDB.swift"),
    ],
    targets: [
        .target(
            name: "AgentVoice",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentVoice",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "AgentVoiceTests",
            dependencies: ["AgentVoice"],
            path: "Tests/AgentVoiceTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
