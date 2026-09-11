// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Anvil",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Anvil", targets: ["Anvil"]),
        .library(name: "AnvilCore", targets: ["AnvilCore"])
    ],
    targets: [
        .target(
            name: "AnvilCore"
        ),
        .executableTarget(
            name: "Anvil",
            dependencies: ["AnvilCore"]
        ),
        .testTarget(
            name: "AnvilCoreTests",
            dependencies: ["AnvilCore"]
        )
    ]
)
