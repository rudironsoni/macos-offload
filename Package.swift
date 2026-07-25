// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "xcode-offload",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "xcode-offload", targets: ["XcodeOffloadCLI"]),
        .library(name: "XcodeOffloadCore", targets: ["XcodeOffloadCore"])
    ],
    targets: [
        .executableTarget(
            name: "XcodeOffloadCLI",
            dependencies: ["XcodeOffloadCore"]
        ),
        .target(
            name: "XcodeOffloadCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration")
            ]
        ),
        .testTarget(
            name: "XcodeOffloadCoreTests",
            dependencies: ["XcodeOffloadCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
