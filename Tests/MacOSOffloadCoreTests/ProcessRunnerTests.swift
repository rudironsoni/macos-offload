import Foundation
import Testing
@testable import MacOSOffloadCore

@Suite(.serialized)
struct ProcessRunnerTests {
    @Test func returnsTimeoutWithoutWaitingForProcessExit() throws {
        let result = try SystemCommandRunner().run(
            "/bin/sleep",
            arguments: ["2"],
            timeoutSeconds: 0.05
        )

        #expect(result.exitCode == 124)
        #expect(result.stderr.contains("command timed out after 0.05 seconds"))
    }

    @Test func preservesSuccessfulTimedCommandOutput() throws {
        let result = try SystemCommandRunner().run(
            "/bin/echo",
            arguments: ["responsive"],
            timeoutSeconds: 1
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "responsive\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func drainsOutputLargerThanPipeBuffer() throws {
        let result = try SystemCommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000"],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 200_000)
    }

    @Test func timeoutTerminatesDescendantProcessGroup() throws {
        let startedAt = Date()
        let result = try SystemCommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; (trap '' TERM; /bin/sleep 30) & wait"],
            timeoutSeconds: 0.05
        )

        #expect(result.exitCode == 124)
        #expect(result.stderr.contains("command timed out after 0.05 seconds"))
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test func doesNotWaitForAnEscapedDescendantHoldingOutputPipes() throws {
        let startedAt = Date()
        let result = try SystemCommandRunner().run(
            "/usr/bin/perl",
            arguments: [
                "-e",
                "if (fork() == 0) { setpgrp(0, 0); sleep 3; exit 0; } exit 0;"
            ],
            timeoutSeconds: 1
        )

        #expect(result.exitCode == 0)
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }
}
