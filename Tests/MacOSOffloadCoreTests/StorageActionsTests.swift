import Foundation
import Testing
@testable import MacOSOffloadCore

@Test func mountSkipsAlreadyMountedDeviceStore() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(
        runner: StubRunner(results: [
            "/sbin/mount": ProcessResult(
                exitCode: 0,
                stdout: "/dev/disk7s1 on /Users/rudi/Library/Developer/CoreSimulator/Devices (apfs, local)\n",
                stderr: ""
            )
        ])
    )

    let plan = try actions.mount(.devices, config: config, dryRun: false)

    #expect(plan == ["already mounted /Users/rudi/Library/Developer/CoreSimulator/Devices"])
}

@Test func mountRequiresSparsebundleOutsideDryRun() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    #expect(throws: CommandError.self) {
        _ = try actions.mount(.devices, config: config, dryRun: false)
    }
}

@Test func mountDryRunAllowsMissingSparsebundle() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    let plan = try actions.mount(.devices, config: config, dryRun: true)

    #expect(plan.contains("mkdir -p /Users/rudi/Library/Developer/CoreSimulator"))
    #expect(plan.contains("/usr/bin/hdiutil attach /Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle -mountpoint /Users/rudi/Library/Developer/CoreSimulator/Devices -nobrowse -owners on"))
}

@Test func systemLaunchdInstallRequiresRootOutsideDryRun() {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    #expect(throws: CommandError.self) {
        _ = try actions.installLaunchd(
            config: config,
            toolPath: "/opt/homebrew/bin/macos-offload",
            scope: .system,
            load: false,
            dryRun: false
        )
    }
}

@Test func userLaunchdInstallPlanDoesNotRequireRoot() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    let plan = try actions.installLaunchd(
        config: config,
        toolPath: "/opt/homebrew/bin/macos-offload",
        scope: .user,
        load: true,
        dryRun: true
    )

    #expect(plan.contains("write /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.mounts-user.plist"))
    #expect(plan.contains("launchctl bootstrap gui/\(getuid()) /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.mounts-user.plist"))
}

@Test func uninstallLaunchdDryRunPlansBothScopes() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    let plan = try actions.uninstallLaunchd(
        config: config,
        scope: .all,
        unload: true,
        dryRun: true
    )

    #expect(plan.contains("launchctl bootout gui/\(getuid()) /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.device-store.plist || true"))
    #expect(plan.contains("rm -f /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.device-store.plist"))
    #expect(plan.contains("launchctl bootout system /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.caches.plist || true"))
    #expect(plan.contains("rm -f /Library/PrivilegedHelperTools/io.github.rudironsoni.macos-offload.mount-coresimulator-caches"))
}

@Test func systemLaunchdDryRunIsRetired() throws {
    let config = StorageConfig(root: "/Volumes/ExternalXcode", home: "/Users/rudi")
    let actions = StorageActions(runner: StubRunner(results: [:]))

    #expect(throws: CommandError.self) {
        _ = try actions.installLaunchd(
            config: config,
            toolPath: "/opt/homebrew/bin/macos-offload",
            scope: .system,
            load: false,
            dryRun: true
        )
    }
}

private struct StubRunner: CommandRunning {
    let results: [String: ProcessResult]

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        results[executable] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
