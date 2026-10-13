// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BirdLock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BirdLock", targets: ["BirdLockApp"]),
        .executable(name: "birdlock-cli", targets: ["BirdLockCLI"]),
        .library(name: "BirdLockCore", targets: ["BirdLockCore"]),
    ],
    targets: [
        .target(
            name: "BirdLockCore",
            path: "Sources/BirdLockCore"
        ),
        .executableTarget(
            name: "BirdLockApp",
            dependencies: ["BirdLockCore"],
            path: "Sources/BirdLockApp"
        ),
        .executableTarget(
            name: "BirdLockCLI",
            dependencies: ["BirdLockCore"],
            path: "Sources/BirdLockCLI"
        ),
    ]
)
