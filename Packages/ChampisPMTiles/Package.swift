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
            // Fichiers copiés un à un : un dossier « Resources » à la racine d'un bundle plat
            // (iOS) fait échouer codesign (« bundle format unrecognized »).
            resources: [
                .copy("Resources/fixture.pmtiles"),
                .copy("Resources/fixture.json"),
                .copy("Resources/pngs.json"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
