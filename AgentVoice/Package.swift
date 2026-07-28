// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentVoice", targets: ["AgentVoice"]),
    ],
    dependencies: [
        // GRDB 在 Task 3（StorageEngine）时加入，Task 2 纯协议无外部依赖
    ],
    targets: [
        .target(
            name: "AgentVoice",
            dependencies: [],
            path: "Sources/AgentVoice"
        ),
        .testTarget(
            name: "AgentVoiceTests",
            dependencies: ["AgentVoice"],
            path: "Tests/AgentVoiceTests"
        ),
    ]
)
