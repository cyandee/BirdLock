// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BirdLock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BirdLock", targets: ["BirdLockApp"]),
        .executable(name: "BirdLockInterpolation", targets: ["BirdLockInterpolation"]),
        .executable(name: "birdlock-cli", targets: ["BirdLockCLI"]),
        .library(name: "BirdLockCore", targets: ["BirdLockCore"]),
        .library(name: "BirdLockAircraftRuntime", targets: ["BirdLockAircraftRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
                 revision: "b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2"),
    ],
    targets: [
        .executableTarget(name: "BirdLockInterpolation", dependencies: ["BirdLockCore"]),
        .target(
            name: "BirdLockCore",
            path: "Sources/BirdLockCore"
        ),
        .target(name: "BirdLockAircraftRuntime", dependencies: [
            "BirdLockCore", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        .executableTarget(
            name: "BirdLockApp",
            dependencies: ["BirdLockCore", "BirdLockAircraftRuntime", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BirdLockApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "BirdLockCLI",
            dependencies: ["BirdLockCore"],
            path: "Sources/BirdLockCLI"
        ),
        .testTarget(name: "BirdLockCoreTests", dependencies: ["BirdLockCore", "BirdLockAircraftRuntime"]),
    ]
)
