import Testing
@testable import MacOSOffloadCore

@Test func rootResolverDoesNotGuessAMachineSpecificDefault() {
    #expect(throws: CommandError.self) {
        try RootResolver.resolveRoot(explicitRoot: nil, environment: [:], runner: StubRunner())
    }
}

@Test func rootResolverUsesProductEnvironmentRoot() throws {
    let root = try RootResolver.resolveRoot(
        explicitRoot: nil,
        environment: ["MACOS_OFFLOAD_ROOT": "/Volumes/ExternalXcode"],
        runner: StubRunner()
    )

    #expect(root == "/Volumes/ExternalXcode")
}

@Test func rootResolverPrefersExplicitRootOverEnvironment() throws {
    let root = try RootResolver.resolveRoot(
        explicitRoot: "/Volumes/ExplicitXcode",
        environment: ["MACOS_OFFLOAD_ROOT": "/Volumes/EnvironmentXcode"],
        runner: StubRunner()
    )

    #expect(root == "/Volumes/ExplicitXcode")
}

@Test func rootResolverUsesConfiguredVolumeName() throws {
    let root = try RootResolver.resolveRoot(
        explicitRoot: nil,
        environment: ["MACOS_OFFLOAD_VOLUME_NAME": "ExternalXcode"],
        runner: StubRunner()
    )

    #expect(root == "/Volumes/ExternalXcode")
}

@Test func rootResolverUsesVolumeUUIDMountPoint() throws {
    let root = try RootResolver.resolveRoot(
        explicitRoot: nil,
        environment: ["MACOS_OFFLOAD_VOLUME_UUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
        runner: StubRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: "   Mount Point:              /Volumes/UUIDXcode\n",
                stderr: ""
            )
        )
    )

    #expect(root == "/Volumes/UUIDXcode")
}

@Test func rootResolverIgnoresEmptyVolumeUUID() throws {
    let root = try RootResolver.resolveRoot(
        explicitRoot: nil,
        environment: [
            "MACOS_OFFLOAD_VOLUME_UUID": "",
            "MACOS_OFFLOAD_VOLUME_NAME": "NamedXcode"
        ],
        runner: StubRunner()
    )

    #expect(root == "/Volumes/NamedXcode")
}

private struct StubRunner: CommandRunning {
    var result = ProcessResult(exitCode: 1, stdout: "", stderr: "")

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        result
    }
}
