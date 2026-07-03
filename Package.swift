// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoCatalog",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoCatalog",
            path: "Sources/PhotoCatalog",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PhotoCatalogTests",
            dependencies: ["PhotoCatalog"],
            path: "Tests/PhotoCatalogTests"
        )
    ]
)
