// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "macos-offload",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "macos-offload", targets: ["MacOSOffloadCLI"]),
        .library(name: "MacOSOffloadCore", targets: ["MacOSOffloadCore"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSOffloadCLI",
            dependencies: ["MacOSOffloadCore"]
        ),
        .target(
            name: "MacOSOffloadCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration")
            ]
        ),
        .testTarget(
            name: "MacOSOffloadCoreTests",
            dependencies: ["MacOSOffloadCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
