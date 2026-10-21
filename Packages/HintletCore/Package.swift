// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HintletCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HintletCore", targets: ["HintletCore"]),
    ],
    targets: [
        .target(name: "HintletCore"),
        .testTarget(
            name: "HintletCoreTests",
            dependencies: ["HintletCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
