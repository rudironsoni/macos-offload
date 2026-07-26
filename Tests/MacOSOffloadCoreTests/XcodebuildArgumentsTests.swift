import Testing
@testable import MacOSOffloadCore

@Test func queryOnlyXcodebuildArgumentsAreNotRewritten() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode")

    #expect(XcodebuildArguments.rewrite(arguments: ["-version"], config: config) == ["-version"])
    #expect(XcodebuildArguments.rewrite(arguments: ["-list", "-project", "App.xcodeproj"], config: config) == ["-list", "-project", "App.xcodeproj"])
}

@Test func xcodebuildArgumentsRouteBuildProductsThroughNormalMountedPath() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")

    let rewritten = XcodebuildArguments.rewrite(
        arguments: [
            "-project",
            "App.xcodeproj",
            "-derivedDataPath",
            "/tmp/old",
            "-clonedSourcePackagesDirPath",
            "/tmp/packages"
        ],
        config: config
    )

    #expect(rewritten.contains("-derivedDataPath"))
    #expect(rewritten.contains("/Users/rudi/Library/Developer/Xcode/DerivedData"))
    #expect(rewritten.contains("-clonedSourcePackagesDirPath"))
    #expect(rewritten.contains("/Volumes/ExternalXcode/Xcode/PackageCache"))
    #expect(rewritten.contains("SYMROOT=/Users/rudi/Library/Developer/Xcode/DerivedData/Build/Products"))
    #expect(rewritten.contains("OBJROOT=/Users/rudi/Library/Developer/Xcode/DerivedData/Build/Intermediates.noindex"))
    #expect(!rewritten.contains { $0.contains("/Volumes/ExternalXcode/Xcode/DerivedData") })
    #expect(rewritten.contains("-project"))
    #expect(rewritten.contains("App.xcodeproj"))
    #expect(!rewritten.contains("/tmp/old"))
    #expect(!rewritten.contains("/tmp/packages"))
}

@Test func xcodebuildArgumentsPreserveWorkspaceAndScheme() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")

    let rewritten = XcodebuildArguments.rewrite(
        arguments: [
            "-workspace",
            "App.xcworkspace",
            "-scheme",
            "App",
            "OTHER_SWIFT_FLAGS=-DDEBUG"
        ],
        config: config
    )

    #expect(rewritten.contains("-workspace"))
    #expect(rewritten.contains("App.xcworkspace"))
    #expect(rewritten.contains("-scheme"))
    #expect(rewritten.contains("App"))
    #expect(rewritten.contains("OTHER_SWIFT_FLAGS=-DDEBUG"))
    #expect(rewritten.contains("CLANG_MODULE_CACHE_PATH=/Users/rudi/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"))
    #expect(rewritten.contains("SWIFT_MODULE_CACHE_PATH=/Users/rudi/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"))
}

@Test func xcodebuildArgumentsDropDanglingStorageFlag() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode")

    let rewritten = XcodebuildArguments.rewrite(
        arguments: ["-scheme", "App", "-derivedDataPath"],
        config: config
    )

    #expect(rewritten.contains("-scheme"))
    #expect(rewritten.contains("App"))
    #expect(rewritten.filter { $0 == "-derivedDataPath" }.count == 1)
}
