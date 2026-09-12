// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Spike",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Spike"
        ),
    ]
)
