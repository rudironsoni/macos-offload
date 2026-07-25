import Foundation
import Testing
@testable import XcodeOffloadCore

@Test func doctorReportsMountedConfiguredSparsebundles() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createDoctorFixture(config: config)

    let runner = DoctorRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: """
            /dev/disk7s1 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled, nobrowse)
            /dev/disk11s1 on \(config.cacheMount) (apfs, local, nodev, nosuid, journaled, nobrowse)
            """,
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: """
            image-path      : \(config.deviceStoreImage)
            image-path      : \(config.cacheImage)
            """,
            stderr: ""
        )
    ])

    let report = Doctor(runner: runner).run(
        config: config,
        requireShims: false,
        validateSimctl: false
    )

    #expect(report.passed)
    #expect(report.checks.contains(DoctorCheck(.pass, "CoreSimulator Devices uses managed sparsebundle backend", detail: config.deviceStoreImage)))
}

@Test func doctorFailsUnsupportedDirectAPFSDeviceStore() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createDoctorFixture(config: config)

    let runner = DoctorRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: """
            /dev/disk7s1 on \(config.deviceMount) (apfs, local, nodev, nosuid, journaled, nobrowse)
            /dev/disk11s1 on \(config.cacheMount) (apfs, local, nodev, nosuid, journaled, nobrowse)
            """,
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: "image-path      : \(config.cacheImage)\n",
            stderr: ""
        ),
        "/usr/sbin/diskutil": ProcessResult(
            exitCode: 0,
            stdout: """
            Volume Name:              XcodeSimulatorDevicesAPFS
            File System Personality:  APFS
            Owners:                   Enabled
            """,
            stderr: ""
        )
    ])

    let report = Doctor(runner: runner).run(
        config: config,
        requireShims: false,
        validateSimctl: false
    )

    #expect(!report.passed)
    #expect(report.checks.contains {
        $0.status == .fail
            && $0.label == "CoreSimulator Devices uses unsupported direct APFS volume"
            && ($0.detail?.contains(config.deviceStoreImage) ?? false)
    })
}

@Test func doctorAllowsInternalCoreSimulatorCacheDirectory() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createDoctorFixture(config: config)

    let runner = DoctorRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: "/dev/disk7s1 on \(config.deviceMount) (apfs, local)\n",
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: "image-path      : \(config.deviceStoreImage)\n",
            stderr: ""
        )
    ])

    let report = Doctor(runner: runner).run(
        config: config,
        requireShims: false,
        validateSimctl: false
    )

    #expect(report.passed)
    #expect(!report.checks.contains { $0.label.contains("CoreSimulator Caches") })
}

@Test func doctorPropagatesSimctlFailureDetail() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createDoctorFixture(config: config)

    let runner = DoctorRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: """
            /dev/disk7s1 on \(config.deviceMount) (apfs, local)
            /dev/disk11s1 on \(config.cacheMount) (apfs, local)
            """,
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: """
            image-path      : \(config.deviceStoreImage)
            image-path      : \(config.cacheImage)
            """,
            stderr: ""
        ),
        "/usr/bin/xcrun": ProcessResult(
            exitCode: 72,
            stdout: "",
            stderr: "simctl unavailable"
        )
    ])

    let report = Doctor(runner: runner).run(
        config: config,
        requireShims: false,
        validateSimctl: true
    )

    #expect(!report.passed)
    #expect(report.checks.contains(DoctorCheck(.fail, "simctl runtimes responds", detail: "simctl unavailable")))
    #expect(report.checks.contains(DoctorCheck(.fail, "simctl devices responds", detail: "simctl unavailable")))
}

@Test func doctorFailsWhenSimctlRuntimeListIsEmpty() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createDoctorFixture(config: config)

    let runner = DoctorRunner(results: [
        "/sbin/mount": ProcessResult(
            exitCode: 0,
            stdout: """
            /dev/disk7s1 on \(config.deviceMount) (apfs, local)
            /dev/disk11s1 on \(config.cacheMount) (apfs, local)
            """,
            stderr: ""
        ),
        "/usr/bin/hdiutil": ProcessResult(
            exitCode: 0,
            stdout: """
            image-path      : \(config.deviceStoreImage)
            image-path      : \(config.cacheImage)
            """,
            stderr: ""
        ),
        "/usr/bin/xcrun": ProcessResult(
            exitCode: 0,
            stdout: "== Runtimes ==\n",
            stderr: ""
        )
    ])

    let report = Doctor(runner: runner).run(
        config: config,
        requireShims: false,
        validateSimctl: true
    )

    #expect(!report.passed)
    #expect(report.checks.contains(DoctorCheck(.fail, "simctl runtimes has available runtimes", detail: "== Runtimes ==")))
}

private struct DoctorRunner: CommandRunning {
    let results: [String: ProcessResult]

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        results[executable] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private func createDoctorFixture(config: StorageConfig) throws {
    let directories = [
        config.xcodeRoot,
        config.coreSimulatorRoot,
        config.derivedData,
        config.packageCache,
        config.tmp,
        config.deviceStoreImage,
        config.cacheImage
    ]

    for directory in directories {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}

private func temporaryDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xcode-offload-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
