// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickyContextCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StickyContextCore", targets: ["StickyContextCore"]),
    ],
    targets: [
        .target(name: "StickyContextCore"),
        .testTarget(
            name: "StickyContextCoreTests",
            dependencies: ["StickyContextCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
