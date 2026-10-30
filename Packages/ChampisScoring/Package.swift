// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChampisScoring",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ChampisScoring", targets: ["ChampisScoring"]),
    ],
    targets: [
        .target(
            name: "ChampisScoring"
        ),
        .testTarget(
            name: "ChampisScoringTests",
            dependencies: ["ChampisScoring"],
            resources: [.copy("Resources/vectors")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
