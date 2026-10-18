// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FerryKit", targets: ["FerryKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "FerryKit",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        ),
        .target(
            name: "FerryApp",
            dependencies: ["FerryKit"]
        ),
        .executableTarget(
            name: "Ferry",
            dependencies: ["FerryApp"]
        ),
        .testTarget(
            name: "FerryAppTests",
            dependencies: ["FerryApp", "FerryKit", .product(name: "Citadel", package: "Citadel")]
        ),
        .testTarget(
            name: "FerryKitTests",
            dependencies: ["FerryKit", .product(name: "Citadel", package: "Citadel")]
        ),
    ]
)
