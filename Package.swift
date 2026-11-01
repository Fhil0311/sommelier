// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SommelierKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SommelierKit", targets: ["SommelierKit"]),
    ],
    targets: [
        .target(name: "SommelierKit"),
        .testTarget(
            name: "SommelierKitTests",
            dependencies: ["SommelierKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
