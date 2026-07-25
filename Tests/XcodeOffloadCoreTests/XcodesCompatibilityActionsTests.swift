import Foundation
import Testing
@testable import XcodeOffloadCore

@Test func xcodesInstallProfileDryRunInstallsMountsEnvironmentAndNoShims() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)

    let actions = try XcodesCompatibilityActions(
        runner: XcodesCompatibilityRunner { _, _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
        environment: [:]
    ).installProfile(
        config: config,
        toolPath: "/usr/local/bin/xcode-offload",
        load: true,
        dryRun: true
    )

    #expect(!actions.contains { $0.contains("XcodeApps.sparsebundle") })
    #expect(!actions.contains { $0.contains("/Applications/Xcodes") })
    #expect(actions.contains("/bin/launchctl setenv XCODES_DIRECTORY \(config.xcodeRoot)"))
    #expect(actions.contains("export XCODES_DIRECTORY=\(config.xcodeRoot)"))
    #expect(!actions.contains { $0.contains("install-shims") || $0.contains("wrap-xcrun") || $0.contains("wrap-xcodebuild") })
}

@Test func xcodesDoctorWarnsWhenXcodesIsMissingButAppleToolsWork() throws {
    let root = try temporaryDirectory()
    let home = try temporaryDirectory()
    let config = StorageConfig(root: root, home: home)
    try createXcodesFixture(config: config)

    let runner = XcodesCompatibilityRunner { executable, arguments, _ in
        switch (executable, arguments) {
        case ("/usr/bin/xcode-select", ["-p"]):
            return ProcessResult(exitCode: 0, stdout: "\(config.xcodeRoot)/Xcode.app/Contents/Developer\n", stderr: "")
        case ("/usr/bin/xcrun", ["-f", "xcodebuild"]):
            return ProcessResult(exitCode: 0, stdout: "/usr/bin/xcodebuild\n", stderr: "")
        case ("/usr/bin/xcodebuild", ["-version"]):
            return ProcessResult(exitCode: 0, stdout: "Xcode 26.0\n", stderr: "")
        case ("/usr/bin/xcrun", ["simctl", "list", "runtimes"]):
            return ProcessResult(exitCode: 0, stdout: "iOS 26.5 - com.apple.CoreSimulator.SimRuntime.iOS-26-5\n", stderr: "")
        case ("/usr/bin/xcrun", ["simctl", "list", "devices", "available"]):
            return ProcessResult(exitCode: 0, stdout: "== Devices ==\n", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(executable) \(arguments)")
        }
    }

    let report = XcodesCompatibilityActions(
        runner: runner,
        environment: ["XCODES_DIRECTORY": config.xcodeRoot, "PATH": "/usr/bin:/bin"]
    ).doctor(config: config, requireXcodes: false, strict: false)

    #expect(report.passed)
    #expect(report.warningCount == 1)
    #expect(report.checks.contains { $0.status == .warn && $0.label == "xcodes executable is optional" })
    #expect(report.checks.contains { $0.status == .pass && $0.label == "External Xcode applications directory exists" })
    #expect(report.checks.contains { $0.status == .pass && $0.label == "simctl runtimes has available runtimes" })
}

@Test func xcodesDoctorCanRequireXcodesExecutable() throws {
    let config = StorageConfig(root: try temporaryDirectory(), home: try temporaryDirectory())
    let report = XcodesCompatibilityActions(
        runner: XcodesCompatibilityRunner { _, _, _ in ProcessResult(exitCode: 1, stdout: "", stderr: "missing") },
        environment: ["PATH": "/usr/bin:/bin"]
    ).doctor(config: config, requireXcodes: true, strict: false)

    #expect(!report.passed)
    #expect(report.checks.contains { $0.status == .fail && $0.label == "xcodes executable is missing" })
}

@Test func xcodesEnvironmentInstallDryRunUsesExplicitDirectoryWithoutRoot() throws {
    let actions = try XcodesCompatibilityActions(
        runner: XcodesCompatibilityRunner { _, _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
        environment: [:]
    ).installEnvironment(directory: "/Applications/Xcodes", dryRun: true)

    #expect(actions == [
        "/bin/launchctl setenv XCODES_DIRECTORY /Applications/Xcodes",
        "export XCODES_DIRECTORY=/Applications/Xcodes"
    ])
}

private final class XcodesCompatibilityRunner: CommandRunning, @unchecked Sendable {
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

private func createXcodesFixture(config: StorageConfig) throws {
    try FileManager.default.createDirectory(atPath: config.mountXcodeAppsImage, withIntermediateDirectories: true)
}

private func temporaryDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xcode-offload-xcodes-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
