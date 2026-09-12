// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentBoard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentBoard", targets: ["AgentBoard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "AgentBoardCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "AgentBoardRuntime",
            dependencies: []
        ),
        .target(
            name: "AgentBoardServer",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")]
        ),
        .target(
            name: "AgentBoardBridge",
            dependencies: [
                "AgentBoardCore",
                "AgentBoardServer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "AgentBoard",
            dependencies: [
                "AgentBoardCore",
                "AgentBoardRuntime",
                "AgentBoardServer",
                "AgentBoardBridge",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "AgentBoardCoreTests", dependencies: ["AgentBoardCore"]),
        .testTarget(name: "AgentBoardRuntimeTests", dependencies: ["AgentBoardRuntime", "AgentBoardCore"]),
        .testTarget(name: "AgentBoardServerTests", dependencies: ["AgentBoardServer"]),
        .testTarget(name: "AgentBoardBridgeTests", dependencies: ["AgentBoardBridge"]),
    ]
)
