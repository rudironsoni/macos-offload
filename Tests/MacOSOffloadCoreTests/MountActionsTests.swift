import Foundation
import Testing
@testable import MacOSOffloadCore

@Test func managedMountInventoryUsesOnlyUserOwnedApplePathsAndExternalSparsebundles() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let mounts = ManagedMounts.all(config: config)

    #expect(mounts.map(\.id) == ["devices", "derived-data", "archives"])
    #expect(mounts.first { $0.id == "derived-data" }?.mountPoint == "/Users/rudi/Library/Developer/Xcode/DerivedData")
    #expect(mounts.allSatisfy { $0.imagePath.hasPrefix("/Volumes/ExternalXcode/Xcode/") })
    #expect(ManagedMounts.legacySystem(config: config).map(\.id) == ["caches", "images", "volumes", "xcode-apps"])
}

@Test func mountInstallDryRunCreatesSparsebundlesAndMountsWithoutSymlinks() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    let actions = try MountActions(runner: MountStubRunner(results: [:])).install(
        config: config,
        toolPath: "/opt/homebrew/bin/macos-offload",
        scope: .user,
        load: true,
        dryRun: true
    )

    #expect(actions.contains { $0.contains("hdiutil create") && $0.contains("DerivedData.sparsebundle") && $0.contains("-type SPARSEBUNDLE") })
    #expect(actions.contains { $0 == "write \(config.mountUserLaunchAgentPath)" })
    #expect(!actions.contains { $0.contains("/Library/Developer/CoreSimulator/Images") })
    #expect(!actions.contains { $0.contains("simctl runtime scan-and-mount") })
    #expect(!actions.contains { $0 == "write \(config.mountSystemLaunchDaemonPath)" })
    #expect(!actions.contains { $0.localizedCaseInsensitiveContains("ln -s") })
}

@Test func mountInstallRejectsSymlinkMountpoints() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    let target = "\(home)/real-devices"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: config.deviceMount).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: config.deviceMount, withDestinationPath: target)

    #expect(throws: CommandError.self) {
        _ = try MountActions(runner: MountStubRunner(results: [:])).install(
            config: config,
            toolPath: "/opt/homebrew/bin/macos-offload",
            scope: .user,
            load: false,
            dryRun: true
        )
    }
}

@Test func mountStatusFailsSymlinkAndWrongBackend() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)
    let target = "\(home)/real-derived-data"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: config.mountDerivedDataMount)
    try FileManager.default.createSymbolicLink(atPath: config.mountDerivedDataMount, withDestinationPath: target)

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: managedMountOutput(config: config),
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: mountHdiutilOutput(config: config, only: ["devices"]),
            stderr: ""
        ),
        "/usr/sbin/diskutil": ProcessResult(
            exitCode: 0,
            stdout: "File System Personality:  APFS\nOwners: Enabled\n",
            stderr: ""
        )
    ])

    let report = MountActions(runner: runner).status(config: config, scope: .user)

    #expect(!report.passed)
    #expect(report.checks.contains { $0.status == .fail && $0.label == "Mount derived-data mountpoint is not a symlink" })
    #expect(report.checks.contains { $0.status == .fail && $0.label == "Mount derived-data uses configured sparsebundle" })
}

@Test func mountStatusExplainsPhysicalExternalAPFSDeviceStore() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk5s2 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled)",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        "/usr/sbin/diskutil": ProcessResult(
            exitCode: 0,
            stdout: """
            File System Personality: APFS
            Owners: Enabled
            Protocol: USB
            Device Location: External
            """,
            stderr: ""
        )
    ])

    let report = MountActions(runner: runner).status(config: config, scope: .user)

    #expect(!report.passed)
    #expect(report.checks.contains {
        $0.status == .fail
            && $0.label == "Mount devices uses supported CoreSimulator backend"
            && ($0.detail?.contains("physical external APFS volumes") ?? false)
    })
}

@Test func mountStatusDoesNotCallExternalDiskImageAPFSPhysicalDeviceStore() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk5s2 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled)",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        "/usr/sbin/diskutil": ProcessResult(
            exitCode: 0,
            stdout: """
            File System Personality: APFS
            Owners: Enabled
            Protocol: Disk Image
            Device Location: External
            """,
            stderr: ""
        )
    ])

    let report = MountActions(runner: runner).status(config: config, scope: .user)

    #expect(!report.passed)
    #expect(report.checks.contains {
        $0.status == .fail
            && $0.label == "Mount devices uses configured sparsebundle"
    })
    #expect(!report.checks.contains {
        $0.label == "Mount devices uses supported CoreSimulator backend"
    })
}

@Test func mountLaunchdPlistPassesPlutilLintAndRunsPersistentAgent() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let templates = MountLaunchdTemplates(config: config, toolPath: "/opt/homebrew/bin/macos-offload")

    try assertPlistLintPasses(templates.userAgentPlist)
    #expect(templates.userAgentPlist.contains("<string>mounts</string>"))
    #expect(templates.userAgentPlist.contains("<string>agent</string>"))
    #expect(templates.userAgentPlist.contains("<key>KeepAlive</key>"))
    #expect(!templates.userAgentPlist.contains("<key>StartInterval</key>"))
}

@Test func userMountInstallUsesUserBackupRootForExistingData() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)
    try "marker".write(
        toFile: "\(config.deviceMount)/existing-file",
        atomically: true,
        encoding: .utf8
    )

    let actions = try MountActions(runner: MountStubRunner(results: [:])).install(
        config: config,
        toolPath: "/opt/homebrew/bin/macos-offload",
        scope: .user,
        load: false,
        dryRun: true
    )

    #expect(actions.contains { $0.contains("mv \(config.deviceMount)") && $0.contains(config.mountUserBackupRoot) })
    #expect(!actions.contains { $0.contains("mv \(config.deviceMount)") && $0.contains(config.mountSystemBackupRoot) })
    #expect(!actions.contains { $0.contains("mv \(config.deviceMount)") && $0.contains(config.mountBackupRoot) })
}

@Test func mountInstallRejectsAlreadyMountedWrongBackend() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk9s1 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled, nobrowse)",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: mountHdiutilOutput(config: config, only: ["derived-data"]),
            stderr: ""
        )
    ])

    #expect(throws: CommandError.self) {
        _ = try MountActions(runner: runner).install(
            config: config,
            toolPath: "/opt/homebrew/bin/macos-offload",
            scope: .user,
            load: false,
            dryRun: true
        )
    }
}

@Test func mountInstallRejectsSystemScopeBeforeInspectingNestedRuntimeMounts() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)
    let runtimeMount = "\(config.mountVolumesMount)/iOS_23F77"
    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk7s1 on \(runtimeMount) (apfs, sealed, local, nodev, nosuid, read-only, journaled, noatime, nobrowse)",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(exitCode: 0, stdout: "", stderr: "")
    ])

    do {
        _ = try MountActions(runner: runner).install(
            config: config,
            toolPath: "/opt/homebrew/bin/macos-offload",
            scope: .system,
            load: false,
            dryRun: true
        )
        Issue.record("expected nested runtime mount to be rejected")
    } catch let error as CommandError {
        #expect(error.exitCode == 78)
        #expect(error.message.contains("system mounts are retired"))
    }
}

@Test func mountRepairDetachesStaleAttachedImageBeforeAttach() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)

    let hdiutilInfo = """
    image-path      : \(config.deviceStoreImage)
    /dev/disk12\tGUID_partition_scheme
    /dev/disk13s1\t41504653-0000-11AA-AA11-00306543ECAC
    """

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        "/usr/bin/hdiutil": ProcessResult(exitCode: 0, stdout: hdiutilInfo, stderr: "")
    ])

    let actions = try MountActions(runner: runner).repair(
        config: config,
        toolPath: "/opt/homebrew/bin/macos-offload",
        scope: .user,
        load: false,
        dryRun: true
    )

    let detachIndex = try #require(actions.firstIndex { $0 == "/usr/bin/hdiutil detach /dev/disk12" })
    let attachIndex = try #require(actions.firstIndex { $0.contains("hdiutil attach") && $0.contains(config.deviceStoreImage) })
    #expect(detachIndex < attachIndex)
    #expect(!actions.contains("/usr/bin/hdiutil detach /dev/disk13s1"))
}

@Test func mountUninstallRefusesToDetachWrongBackend() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createMountFixture(config: config)

    let runner = MountStubRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk9s1 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled, nobrowse)",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: mountHdiutilOutput(config: config, only: ["derived-data"]),
            stderr: ""
        )
    ])

    #expect(throws: CommandError.self) {
        _ = try MountActions(runner: runner).uninstall(
            config: config,
            scope: .user,
            unload: false,
            dryRun: true
        )
    }
}

private struct MountStubRunner: CommandRunning {
    let results: [String: ProcessResult]

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        results[executable] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private func createMountFixture(config: StorageConfig) throws {
    for managedMount in ManagedMounts.all(config: config) {
        try FileManager.default.createDirectory(
            atPath: managedMount.imagePath,
            withIntermediateDirectories: true
        )
        if managedMount.mountPoint.hasPrefix(config.home) {
            try FileManager.default.createDirectory(
                atPath: managedMount.mountPoint,
                withIntermediateDirectories: true
            )
        }
    }
}

private func managedMountOutput(config: StorageConfig) -> String {
    ManagedMounts.all(config: config)
        .map { "/dev/disk1s1 on \($0.mountPoint) (apfs, local, nodev, nosuid, journaled, nobrowse)" }
        .joined(separator: "\n")
}

private func mountHdiutilOutput(config: StorageConfig, only ids: Set<String>? = nil) -> String {
    ManagedMounts.all(config: config)
        .filter { ids?.contains($0.id) ?? true }
        .map { managedMount in
            """
            image-path      : \(managedMount.imagePath)
            /dev/disk1s1\t41504653-0000-11AA-AA11-00306543ECAC\t\(managedMount.mountPoint)
            """
        }
        .joined(separator: "\n================================================\n")
}

private func temporaryDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macos-offload-mounts-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func assertPlistLintPasses(_ plist: String) throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macos-offload-mounts-test-\(UUID().uuidString).plist")
    try plist.write(to: url, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: url)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    process.arguments = ["-lint", url.path]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
}

private func assertZshSyntaxPasses(_ script: String) throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macos-offload-mounts-test-\(UUID().uuidString).zsh")
    try script.write(to: url, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: url)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-n", url.path]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
}
