import Foundation
import Testing
@testable import XcodeOffloadCore

@Test func supportedMountInventoryContainsOnlyUserOwnedPaths() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")

    #expect(ManagedMounts.all(config: config).map(\.id) == [
        "devices",
        "derived-data",
        "archives"
    ])
}

@Test func systemMountInstallationIsRetired() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")

    do {
        _ = try MountActions(runner: ReliabilityStubRunner()).install(
            config: config,
            toolPath: "/opt/homebrew/bin/xcode-offload",
            scope: .system,
            load: false,
            dryRun: true
        )
        Issue.record("expected system mount installation to be rejected")
    } catch let error as CommandError {
        #expect(error.exitCode == 78)
        #expect(error.message.contains("system mounts are retired"))
    }
}

@Test func userLaunchAgentRunsPersistentEventAgentWithoutPolling() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let plist = MountLaunchdTemplates(
        config: config,
        toolPath: "/opt/homebrew/bin/xcode-offload"
    ).userAgentPlist

    #expect(plist.contains("<string>agent</string>"))
    #expect(plist.contains("<key>KeepAlive</key>"))
    #expect(!plist.contains("<key>StartInterval</key>"))
    #expect(!plist.contains("<string>system</string>"))
}

@Test func xcodesProfileUsesDirectExternalDirectory() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = try XcodesCompatibilityActions(
        runner: ReliabilityStubRunner(),
        environment: [:]
    ).installProfile(
        config: config,
        toolPath: "/opt/homebrew/bin/xcode-offload",
        load: false,
        dryRun: true
    )

    #expect(actions.contains("/bin/launchctl setenv XCODES_DIRECTORY /Volumes/ExternalXcode/Xcode"))
    #expect(!actions.contains { $0.contains("/Applications/Xcodes") })
}

@Test func reconciliationRejectsAChangedExternalVolumeUUID() throws {
    let root = try reliabilityTemporaryDirectory()
    let home = try reliabilityTemporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try FileManager.default.createDirectory(
        atPath: config.applicationSupportDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(
        MountConfiguration(rootPath: root, volumeUUID: "EXPECTED-UUID")
    ).write(to: URL(fileURLWithPath: config.mountConfigurationPath))

    let runner = ReliabilityHandlerRunner { executable, _, _ in
        if executable == "/usr/sbin/diskutil" {
            return ProcessResult(
                exitCode: 0,
                stdout: "Volume UUID: ACTUAL-UUID\n",
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
    let actions = MountActions(runner: runner)

    #expect(throws: CommandError.self) {
        _ = try actions.reconcile(config: config, dryRun: false)
    }
    #expect(actions.status(config: config, scope: .user).lifecycle?.state == .blockedWrongVolume)
}

@Test func reconciliationRejectsAChangedConfiguredRootOnTheSameVolume() throws {
    let root = try reliabilityTemporaryDirectory()
    let home = try reliabilityTemporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try FileManager.default.createDirectory(
        atPath: config.applicationSupportDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(
        MountConfiguration(rootPath: "\(root)-old", volumeUUID: "SAME-UUID")
    ).write(to: URL(fileURLWithPath: config.mountConfigurationPath))

    let runner = ReliabilityHandlerRunner { executable, _, _ in
        if executable == "/usr/sbin/diskutil" {
            return ProcessResult(exitCode: 0, stdout: "Volume UUID: SAME-UUID\n", stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    #expect(throws: CommandError.self) {
        _ = try MountActions(runner: runner).reconcile(config: config, dryRun: false)
    }
}

@Test func uninstallAllIncludesUserMountDetachment() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let runner = ReliabilityHandlerRunner { executable, _, _ in
        switch executable {
        case "/sbin/mount":
            return ProcessResult(
                exitCode: 0,
                stdout: ManagedMounts.user(config: config)
                    .map { "/dev/disk1s1 on \($0.mountPoint) (apfs, local, owners)" }
                    .joined(separator: "\n"),
                stderr: ""
            )
        case "/usr/bin/hdiutil":
            return ProcessResult(
                exitCode: 0,
                stdout: ManagedMounts.user(config: config)
                    .map {
                        """
                        image-path      : \($0.imagePath)
                        /dev/disk1s1\tAPFS\t\($0.mountPoint)
                        """
                    }
                    .joined(separator: "\n================================================\n"),
                stderr: ""
            )
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
    let actions = try MountActions(runner: runner).uninstall(
        config: config,
        scope: .all,
        unload: true,
        onReboot: true,
        dryRun: true
    )

    for mount in ManagedMounts.user(config: config) {
        #expect(actions.contains { $0.contains("detach") && $0.contains(mount.mountPoint) })
    }
}

@Test func runtimeReconciliationNeverMovesUnexpectedMountpointData() throws {
    let root = try reliabilityTemporaryDirectory()
    let home = try reliabilityTemporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    for mount in ManagedMounts.user(config: config) {
        try FileManager.default.createDirectory(atPath: mount.imagePath, withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(atPath: config.deviceMount, withIntermediateDirectories: true)
    let marker = "\(config.deviceMount)/must-stay"
    try "data".write(toFile: marker, atomically: true, encoding: .utf8)

    let actions = MountActions(runner: ReliabilityStubRunner())
    #expect(throws: CommandError.self) {
        _ = try actions.reconcile(config: config, dryRun: false)
    }
    #expect(FileManager.default.fileExists(atPath: marker))
    #expect(actions.status(config: config, scope: .user).lifecycle?.state == .failed)
}

@Test func simulatorWrapperFailsWithoutKillingCoreSimulatorProcesses() throws {
    let root = try reliabilityTemporaryDirectory()
    let home = try reliabilityTemporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    for mount in ManagedMounts.user(config: config) {
        try FileManager.default.createDirectory(atPath: mount.imagePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mount.mountPoint, withIntermediateDirectories: true)
    }

    let recorder = ReliabilityCallRecorder()
    let runner = ReliabilityHandlerRunner { executable, arguments, _ in
        recorder.calls.append((executable, arguments))
        switch executable {
        case "/sbin/mount":
            return ProcessResult(
                exitCode: 0,
                stdout: ManagedMounts.user(config: config)
                    .map { "/dev/disk1s1 on \($0.mountPoint) (apfs, local, owners)" }
                    .joined(separator: "\n"),
                stderr: ""
            )
        case "/usr/bin/hdiutil":
            return ProcessResult(
                exitCode: 0,
                stdout: ManagedMounts.user(config: config)
                    .map {
                        """
                        image-path      : \($0.imagePath)
                        /dev/disk1s1\tAPFS\t\($0.mountPoint)
                        """
                    }
                    .joined(separator: "\n================================================\n"),
                stderr: ""
            )
        case "/usr/bin/xcrun":
            return ProcessResult(exitCode: 61, stdout: "", stderr: "Failed to connect")
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    do {
        try WrapperRunner(runner: runner).runSimctl(arguments: ["list", "devices"], config: config)
    } catch let exit as ExitRequested {
        #expect(exit.code == 61)
    }

    #expect(!recorder.calls.contains { $0.0 == "/usr/bin/pkill" })
    #expect(recorder.calls.filter { $0.0 == "/usr/bin/xcrun" }.count == 1)
}

private struct ReliabilityStubRunner: CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private final class ReliabilityHandlerRunner: CommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (String, [String], [String: String]) throws -> ProcessResult
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        try handler(executable, arguments, environment)
    }
}

private final class ReliabilityCallRecorder: @unchecked Sendable {
    var calls: [(String, [String])] = []
}

private func reliabilityTemporaryDirectory() throws -> String {
    let path = "\(NSTemporaryDirectory())xcode-offload-reliability-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
