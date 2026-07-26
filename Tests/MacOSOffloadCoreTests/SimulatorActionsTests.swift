import Foundation
import Testing
@testable import MacOSOffloadCore

@Test func simulatorListsAvailableDevicesByDefault() throws {
    let runner = RecordingRunner { _, arguments, _ in
        #expect(arguments == ["simctl", "list", "devices", "available"])
        return ProcessResult(exitCode: 0, stdout: "== Devices ==\n", stderr: "")
    }

    let output = try SimulatorActions(runner: runner).listDevices(availableOnly: true)

    #expect(output == "== Devices ==\n")
}

@Test func simulatorListsAllDevicesWhenRequested() throws {
    let runner = RecordingRunner { _, arguments, _ in
        #expect(arguments == ["simctl", "list", "devices"])
        return ProcessResult(exitCode: 0, stdout: "== Devices ==\n", stderr: "")
    }

    let output = try SimulatorActions(runner: runner).listDevices(availableOnly: false)

    #expect(output == "== Devices ==\n")
}

@Test func simulatorRecreateDeletesCreatesBootsAndWaits() throws {
    let runner = RecordingRunner { _, arguments, environment in
        switch arguments {
        case ["simctl", "shutdown", "Orlix"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "delete", "Orlix"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "create", "Orlix", "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "com.apple.CoreSimulator.SimRuntime.iOS-26-5"]:
            return ProcessResult(exitCode: 0, stdout: "NEW-UDID\n", stderr: "")
        case ["simctl", "boot", "NEW-UDID"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "bootstatus", "NEW-UDID", "-b"]:
            #expect(environment["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT"] == "42")
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(arguments)")
        }
    }

    let plan = try SimulatorActions(runner: runner).recreate(
        name: "Orlix",
        deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        boot: true,
        bootTimeoutSeconds: 42
    )

    #expect(plan == [
        "xcrun simctl delete Orlix",
        "xcrun simctl create Orlix com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "xcrun simctl boot NEW-UDID",
        "xcrun simctl bootstatus NEW-UDID -b"
    ])
}

@Test func simulatorRecreateAcceptsAlreadyBootedDevice() throws {
    let runner = RecordingRunner { _, arguments, _ in
        switch arguments {
        case ["simctl", "create", "Orlix", "device", "runtime"]:
            return ProcessResult(exitCode: 0, stdout: "BOOTED-UDID\n", stderr: "")
        case ["simctl", "boot", "BOOTED-UDID"]:
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Unable to boot device in current state: Booted")
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    let plan = try SimulatorActions(runner: runner).recreate(
        name: "Orlix",
        deviceType: "device",
        runtime: "runtime",
        boot: true,
        bootTimeoutSeconds: 5
    )

    #expect(plan.contains("xcrun simctl boot BOOTED-UDID"))
}

@Test func simulatorVerifyBootsSpawnsAndCapturesScreenshot() throws {
    let runner = RecordingRunner { _, arguments, environment in
        switch arguments {
        case ["simctl", "list", "devices", "available"]:
            return ProcessResult(
                exitCode: 0,
                stdout: """
                == Devices ==
                -- iOS 26.5 --
                    Orlix (VERIFY-UDID) (Shutdown)
                """,
                stderr: ""
            )
        case ["simctl", "boot", "VERIFY-UDID"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "bootstatus", "VERIFY-UDID", "-b"]:
            #expect(environment["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT"] == "9")
            return ProcessResult(exitCode: 0, stdout: "Finished\n", stderr: "")
        case ["simctl", "spawn", "VERIFY-UDID", "/bin/echo", "responsive"]:
            return ProcessResult(exitCode: 0, stdout: "responsive\n", stderr: "")
        case ["simctl", "io", "VERIFY-UDID", "screenshot", "/tmp/verify.png"]:
            return ProcessResult(exitCode: 0, stdout: "Wrote screenshot\n", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(arguments)")
        }
    }

    let plan = try SimulatorActions(runner: runner).verify(
        name: "Orlix",
        udid: nil,
        bootTimeoutSeconds: 9,
        screenshotPath: "/tmp/verify.png"
    )

    #expect(plan == [
        "xcrun simctl boot VERIFY-UDID",
        "xcrun simctl bootstatus VERIFY-UDID -b",
        "xcrun simctl spawn VERIFY-UDID /bin/echo responsive",
        "xcrun simctl io VERIFY-UDID screenshot /tmp/verify.png"
    ])
}

@Test func simulatorResetCanVerifyNewDevice() throws {
    let runner = RecordingRunner { _, arguments, environment in
        switch arguments {
        case ["simctl", "shutdown", "Orlix"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "delete", "Orlix"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "create", "Orlix", "device", "runtime"]:
            return ProcessResult(exitCode: 0, stdout: "RESET-UDID\n", stderr: "")
        case ["simctl", "boot", "RESET-UDID"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["simctl", "bootstatus", "RESET-UDID", "-b"]:
            #expect(environment["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT"] == "11")
            return ProcessResult(exitCode: 0, stdout: "Finished\n", stderr: "")
        case ["simctl", "spawn", "RESET-UDID", "/bin/echo", "responsive"]:
            return ProcessResult(exitCode: 0, stdout: "responsive\n", stderr: "")
        case ["simctl", "io", "RESET-UDID", "screenshot", "/tmp/reset.png"]:
            return ProcessResult(exitCode: 0, stdout: "Wrote screenshot\n", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(arguments)")
        }
    }

    let plan = try SimulatorActions(runner: runner).reset(
        name: "Orlix",
        deviceType: "device",
        runtime: "runtime",
        boot: false,
        verify: true,
        bootTimeoutSeconds: 11,
        screenshotPath: "/tmp/reset.png"
    )

    #expect(plan == [
        "xcrun simctl delete Orlix",
        "xcrun simctl create Orlix device runtime",
        "xcrun simctl boot RESET-UDID",
        "xcrun simctl bootstatus RESET-UDID -b",
        "xcrun simctl spawn RESET-UDID /bin/echo responsive",
        "xcrun simctl io RESET-UDID screenshot /tmp/reset.png"
    ])
}

@Test func simulatorOpenByNameSkipsBootWhenDeviceIsAlreadyBooted() throws {
    let runner = RecordingRunner { executable, arguments, environment in
        switch (executable, arguments) {
        case ("/usr/bin/xcrun", ["simctl", "list", "devices", "available"]):
            return ProcessResult(
                exitCode: 0,
                stdout: """
                == Devices ==
                -- iOS 26.5 --
                    Orlix-iPhone-15-Pro-Max (C47ED88D-0D0A-420D-8C78-D4C1D34A276D) (Booted)
                """,
                stderr: ""
            )
        case ("/usr/bin/xcrun", ["simctl", "boot", "C47ED88D-0D0A-420D-8C78-D4C1D34A276D"]):
            Issue.record("open should not call simctl boot when the parsed device is already Booted")
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Unable to boot device in current state: Booted")
        case ("/usr/bin/xcrun", ["simctl", "bootstatus", "C47ED88D-0D0A-420D-8C78-D4C1D34A276D", "-b"]):
            #expect(environment["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT"] == "7")
            return ProcessResult(exitCode: 0, stdout: "Device already booted, nothing to do.\n", stderr: "")
        case ("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", "C47ED88D-0D0A-420D-8C78-D4C1D34A276D"]):
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ("/usr/bin/osascript", ["-e", "tell application \"Simulator\" to activate"]):
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(executable) \(arguments)")
        }
    }

    let plan = try SimulatorActions(runner: runner).open(
        name: "Orlix-iPhone-15-Pro-Max",
        udid: nil,
        bootTimeoutSeconds: 7
    )

    #expect(plan == [
        "xcrun simctl boot C47ED88D-0D0A-420D-8C78-D4C1D34A276D # already booted",
        "xcrun simctl bootstatus C47ED88D-0D0A-420D-8C78-D4C1D34A276D -b",
        "open -a Simulator --args -CurrentDeviceUDID C47ED88D-0D0A-420D-8C78-D4C1D34A276D",
        "osascript -e 'tell application \"Simulator\" to activate'"
    ])
}

@Test func simulatorOpenByUDIDAcceptsAlreadyBootedError() throws {
    let runner = RecordingRunner { executable, arguments, _ in
        switch (executable, arguments) {
        case ("/usr/bin/xcrun", ["simctl", "boot", "BOOTED-UDID"]):
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Unable to boot device in current state: Booted")
        case ("/usr/bin/xcrun", ["simctl", "bootstatus", "BOOTED-UDID", "-b"]):
            return ProcessResult(exitCode: 0, stdout: "Device already booted, nothing to do.\n", stderr: "")
        case ("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", "BOOTED-UDID"]):
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ("/usr/bin/osascript", ["-e", "tell application \"Simulator\" to activate"]):
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(executable) \(arguments)")
        }
    }

    let plan = try SimulatorActions(runner: runner).open(
        name: nil,
        udid: "BOOTED-UDID",
        bootTimeoutSeconds: 5
    )

    #expect(plan.contains("xcrun simctl boot BOOTED-UDID"))
    #expect(plan.contains("open -a Simulator --args -CurrentDeviceUDID BOOTED-UDID"))
}

@Test func simulatorOpenByNameRequiresUDIDWhenNameIsAmbiguous() {
    let runner = RecordingRunner { _, arguments, _ in
        switch arguments {
        case ["simctl", "list", "devices", "available"]:
            return ProcessResult(
                exitCode: 0,
                stdout: """
                == Devices ==
                -- iOS 26.5 --
                    Orlix (FIRST-UDID) (Shutdown)
                    Orlix (SECOND-UDID) (Shutdown)
                """,
                stderr: ""
            )
        default:
            return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected \(arguments)")
        }
    }

    #expect(throws: CommandError.self) {
        _ = try SimulatorActions(runner: runner).open(
            name: "Orlix",
            udid: nil,
            bootTimeoutSeconds: 5
        )
    }
}

@Test func simulatorRecreateFailsWhenBootstatusFails() {
    let runner = RecordingRunner { _, arguments, _ in
        switch arguments {
        case ["simctl", "create", "Orlix", "device", "runtime"]:
            return ProcessResult(exitCode: 0, stdout: "UDID\n", stderr: "")
        case ["simctl", "bootstatus", "UDID", "-b"]:
            return ProcessResult(exitCode: 65, stdout: "", stderr: "Data Migration Failed")
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    #expect(throws: CommandError.self) {
        _ = try SimulatorActions(runner: runner).recreate(
            name: "Orlix",
            deviceType: "device",
            runtime: "runtime",
            boot: true,
            bootTimeoutSeconds: 5
        )
    }
}

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
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
