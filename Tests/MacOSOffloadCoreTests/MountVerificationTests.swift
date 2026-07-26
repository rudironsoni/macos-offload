import Foundation
import Testing
@testable import MacOSOffloadCore

@Test func mountVerificationUserModeRunsToolSubcommandsAndCleansArtifacts() throws {
    let scratchRoot = try temporaryVerificationDirectory()
    let runner = VerificationRecordingRunner()
    var events: [String] = []

    try MountVerification(runner: runner).run(
        options: MountVerificationOptions(
            mode: .user,
            scratchRoot: scratchRoot,
            home: "/Users/rudi",
            toolPath: "/tmp/macos-offload"
        )
    ) { events.append($0) }

    #expect(runner.calls.map(\.arguments).contains { $0.starts(with: ["mounts", "install"]) && $0.contains("--dry-run") })
    #expect(runner.calls.map(\.arguments).contains { $0.starts(with: ["mounts", "install"]) && !$0.contains("--dry-run") })
    #expect(runner.calls.map(\.arguments).contains { $0.starts(with: ["mounts", "status"]) && $0.contains("--json") })
    #expect(runner.calls.map(\.arguments).contains { $0.starts(with: ["mounts", "uninstall"]) })
    #expect(events.contains("==> mount verification passed"))
    #expect((try FileManager.default.contentsOfDirectory(atPath: scratchRoot)).isEmpty)
}

@Test func mountVerificationRejectsUnsafeScratchRoot() throws {
    #expect(throws: CommandError.self) {
        try MountVerification(runner: VerificationRecordingRunner()).run(
            options: MountVerificationOptions(
                mode: .user,
                scratchRoot: "/Volumes",
                home: "/Users/rudi",
                toolPath: "/tmp/macos-offload"
            )
        ) { _ in }
    }
}

@Test func mountVerificationSystemModeRequiresExplicitGate() throws {
    let scratchRoot = try temporaryVerificationDirectory()

    #expect(throws: CommandError.self) {
        try MountVerification(runner: VerificationRecordingRunner()).run(
            options: MountVerificationOptions(
                mode: .system,
                scratchRoot: scratchRoot,
                home: "/Users/rudi",
                toolPath: "/tmp/macos-offload"
            )
        ) { _ in }
    }
}

@Test func mountVerificationE2ERequiresExplicitSimulatorDeletionGate() throws {
    let scratchRoot = try temporaryVerificationDirectory()

    #expect(throws: CommandError.self) {
        try MountVerification(runner: VerificationRecordingRunner()).run(
            options: MountVerificationOptions(
                mode: .e2e,
                scratchRoot: scratchRoot,
                home: "/Users/rudi",
                toolPath: "/tmp/macos-offload"
            )
        ) { _ in }
    }
}

private struct VerificationCall: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

private final class VerificationRecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [VerificationCall] = []

    var calls: [VerificationCall] {
        lock.withLock {
            storedCalls
        }
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        lock.withLock {
            storedCalls.append(VerificationCall(executable: executable, arguments: arguments, environment: environment))
        }
        return ProcessResult(exitCode: 0, stdout: "ok\n", stderr: "")
    }
}

private func temporaryVerificationDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macos-offload-verify-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
