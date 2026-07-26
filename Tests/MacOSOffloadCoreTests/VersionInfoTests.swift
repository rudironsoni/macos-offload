import Testing
@testable import MacOSOffloadCore

@Test func versionDisplayIncludesBuildMetadata() {
    let version = VersionInfo(
        version: "0.2.0-dev.12+abc1234",
        commit: "abc1234",
        buildDate: "2026-07-02T12:00:00Z",
        dirty: true
    )

    #expect(version.displayString == "macos-offload 0.2.0-dev.12+abc1234, commit abc1234, built 2026-07-02T12:00:00Z, dirty")
}

@Test func minimalVersionDisplayReturnsVersionOnly() {
    let version = VersionInfo(version: "0.1.0", commit: "", buildDate: "", dirty: false)

    #expect(version.displayString == "0.1.0")
}
