// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChampisPMTiles",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ChampisPMTiles", targets: ["ChampisPMTiles"]),
    ],
    targets: [
        .target(
            name: "ChampisPMTiles"
        ),
        .testTarget(
            name: "ChampisPMTilesTests",
            dependencies: ["ChampisPMTiles"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
