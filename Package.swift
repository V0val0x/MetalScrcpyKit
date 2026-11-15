// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalScrcpyKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetalScrcpyKit",
            targets: ["MetalScrcpyKit"]
        )
    ],
    targets: [
        .target(
            name: "MetalScrcpyKit",
            path: "Sources/MetalScrcpyKit"
        ),
        .testTarget(
            name: "MetalScrcpyKitTests",
            dependencies: ["MetalScrcpyKit"],
            path: "Tests/MetalScrcpyKitTests"
        )
    ]
)
