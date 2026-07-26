import Foundation

public struct SimulatorActions {
    private let runner: CommandRunning

    public init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    public func listRuntimes() throws -> String {
        try runSimctl(["list", "runtimes"])
    }

    public func listDevices(availableOnly: Bool) throws -> String {
        var arguments = ["list", "devices"]
        if availableOnly {
            arguments.append("available")
        }
        return try runSimctl(arguments)
    }

    public func recreate(
        name: String,
        deviceType: String,
        runtime: String,
        boot: Bool,
        bootTimeoutSeconds: Int
    ) throws -> [String] {
        var actions: [String] = []

        _ = try? runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "shutdown", name],
            environment: [:],
            timeoutSeconds: 60
        )
        _ = try? runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "delete", name],
            environment: [:],
            timeoutSeconds: 60
        )
        actions.append("xcrun simctl delete \(name.shellQuoted)")

        let createResult = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "create", name, deviceType, runtime],
            environment: [:],
            timeoutSeconds: 60
        )
        guard createResult.succeeded else {
            throw CommandError(nonEmptyOutput(from: createResult), exitCode: createResult.exitCode)
        }

        let udid = createResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        actions.append("xcrun simctl create \(name.shellQuoted) \(deviceType.shellQuoted) \(runtime.shellQuoted)")

        if boot {
            actions.append(contentsOf: try bootAndWait(udid: udid, bootTimeoutSeconds: bootTimeoutSeconds))
        }

        return actions
    }

    public func reset(
        name: String,
        deviceType: String,
        runtime: String,
        boot: Bool,
        verify: Bool,
        bootTimeoutSeconds: Int,
        screenshotPath: String?
    ) throws -> [String] {
        var actions = try recreate(
            name: name,
            deviceType: deviceType,
            runtime: runtime,
            boot: boot || verify,
            bootTimeoutSeconds: bootTimeoutSeconds
        )

        if verify {
            actions.append(
                contentsOf: try verifyResponsiveAndScreenshot(
                    udid: bootedUDID(from: actions),
                    screenshotPath: screenshotPath,
                    timeoutSeconds: bootTimeoutSeconds
                )
            )
        }

        return actions
    }

    public func verify(
        name: String?,
        udid explicitUDID: String?,
        bootTimeoutSeconds: Int,
        screenshotPath: String?
    ) throws -> [String] {
        let device = try resolveDevice(name: name, udid: explicitUDID)
        var actions = try bootAndWait(udid: device.udid, bootTimeoutSeconds: bootTimeoutSeconds)
        actions.append(
            contentsOf: try verifyResponsiveAndScreenshot(
                udid: device.udid,
                screenshotPath: screenshotPath,
                timeoutSeconds: bootTimeoutSeconds
            )
        )

        return actions
    }

    private func verifyResponsiveAndScreenshot(
        udid: String,
        screenshotPath: String?,
        timeoutSeconds: Int
    ) throws -> [String] {
        var actions: [String] = []

        let spawnResult = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "spawn", udid, "/bin/echo", "responsive"],
            environment: [:],
            timeoutSeconds: TimeInterval(timeoutSeconds)
        )
        guard spawnResult.succeeded else {
            throw CommandError(nonEmptyOutput(from: spawnResult), exitCode: spawnResult.exitCode)
        }
        let spawnOutput = spawnResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spawnOutput == "responsive" else {
            throw CommandError("simulator did not return responsive marker", exitCode: 65)
        }
        actions.append("xcrun simctl spawn \(udid.shellQuoted) /bin/echo responsive")

        let screenshot = screenshotPath ?? "\(NSTemporaryDirectory())macos-offload-\(udid)-screenshot.png"
        let screenshotResult = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "io", udid, "screenshot", screenshot],
            environment: [:],
            timeoutSeconds: TimeInterval(timeoutSeconds)
        )
        guard screenshotResult.succeeded else {
            throw CommandError(nonEmptyOutput(from: screenshotResult), exitCode: screenshotResult.exitCode)
        }
        actions.append("xcrun simctl io \(udid.shellQuoted) screenshot \(screenshot.shellQuoted)")

        return actions
    }

    public func open(
        name: String?,
        udid explicitUDID: String?,
        bootTimeoutSeconds: Int
    ) throws -> [String] {
        guard name != nil || explicitUDID != nil else {
            throw CommandError("missing required option: --name or --udid", exitCode: 64)
        }
        guard !(name != nil && explicitUDID != nil) else {
            throw CommandError("pass either --name or --udid, not both", exitCode: 64)
        }

        var actions: [String] = []
        let device = try resolveDevice(name: name, udid: explicitUDID)
        let isKnownBooted = device.state.localizedCaseInsensitiveCompare("Booted") == .orderedSame

        if isKnownBooted {
            actions.append("xcrun simctl boot \(device.udid.shellQuoted) # already booted")
        } else {
            actions.append(contentsOf: try bootAndWait(udid: device.udid, bootTimeoutSeconds: bootTimeoutSeconds))
        }

        if isKnownBooted {
            let bootStatus = try runner.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "bootstatus", device.udid, "-b"],
                environment: ["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT": "\(bootTimeoutSeconds)"],
                timeoutSeconds: TimeInterval(bootTimeoutSeconds)
            )
            guard bootStatus.succeeded else {
                throw CommandError(nonEmptyOutput(from: bootStatus), exitCode: bootStatus.exitCode)
            }
            actions.append("xcrun simctl bootstatus \(device.udid.shellQuoted) -b")
        }

        let openResult = try runner.run(
            "/usr/bin/open",
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.udid],
            environment: [:],
            timeoutSeconds: 30
        )
        guard openResult.succeeded else {
            throw CommandError(nonEmptyOutput(from: openResult), exitCode: openResult.exitCode)
        }
        actions.append("open -a Simulator --args -CurrentDeviceUDID \(device.udid.shellQuoted)")

        let activateResult = try runner.run(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Simulator\" to activate"],
            environment: [:],
            timeoutSeconds: 30
        )
        guard activateResult.succeeded else {
            throw CommandError(nonEmptyOutput(from: activateResult), exitCode: activateResult.exitCode)
        }
        actions.append("osascript -e 'tell application \"Simulator\" to activate'")

        return actions
    }

    private func bootAndWait(udid: String, bootTimeoutSeconds: Int) throws -> [String] {
        var actions: [String] = []
        let bootResult = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "boot", udid],
            environment: [:],
            timeoutSeconds: TimeInterval(bootTimeoutSeconds)
        )
        if !bootResult.succeeded && !isAlreadyBooted(bootResult) {
            throw CommandError(nonEmptyOutput(from: bootResult), exitCode: bootResult.exitCode)
        }
        actions.append("xcrun simctl boot \(udid.shellQuoted)")

        let bootStatus = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", udid, "-b"],
            environment: ["SIMCTL_CHILD_BOOTSTATUS_TIMEOUT": "\(bootTimeoutSeconds)"],
            timeoutSeconds: TimeInterval(bootTimeoutSeconds)
        )
        guard bootStatus.succeeded else {
            throw CommandError(nonEmptyOutput(from: bootStatus), exitCode: bootStatus.exitCode)
        }
        actions.append("xcrun simctl bootstatus \(udid.shellQuoted) -b")
        return actions
    }

    private func bootedUDID(from actions: [String]) throws -> String {
        guard let udid = actions
            .first(where: { $0.hasPrefix("xcrun simctl boot ") })?
            .split(separator: " ")
            .last
            .map(String.init),
            !udid.isEmpty else {
            throw CommandError("simulator reset could not resolve created UDID", exitCode: 65)
        }
        return udid
    }

    private func runSimctl(_ arguments: [String]) throws -> String {
        let result = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl"] + arguments,
            environment: [:],
            timeoutSeconds: 30
        )
        guard result.succeeded else {
            throw CommandError(nonEmptyOutput(from: result), exitCode: result.exitCode)
        }
        return result.stdout
    }

    private func resolveDevice(name: String?, udid explicitUDID: String?) throws -> SimulatorDevice {
        if let explicitUDID {
            return SimulatorDevice(name: explicitUDID, udid: explicitUDID, state: "")
        }

        guard let name else {
            throw CommandError("missing required option: --name or --udid", exitCode: 64)
        }

        let devicesOutput = try runSimctl(["list", "devices", "available"])
        let matches = parseDevices(devicesOutput).filter { $0.name == name }
        guard !matches.isEmpty else {
            throw CommandError("simulator not found: \(name)", exitCode: 66)
        }

        if matches.count == 1 {
            return matches[0]
        }

        let bootedMatches = matches.filter { $0.state.localizedCaseInsensitiveCompare("Booted") == .orderedSame }
        if bootedMatches.count == 1 {
            return bootedMatches[0]
        }

        let choices = matches
            .map { "  \($0.name) (\($0.udid)) (\($0.state))" }
            .joined(separator: "\n")
        throw CommandError("multiple simulators named \(name.shellQuoted). Pass --udid.\n\(choices)", exitCode: 65)
    }

    private func parseDevices(_ output: String) -> [SimulatorDevice] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parseDeviceLine(String($0)) }
    }

    private func parseDeviceLine(_ line: String) -> SimulatorDevice? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("=="),
              !trimmed.hasPrefix("--"),
              trimmed.hasSuffix(")") else {
            return nil
        }

        guard let stateStart = trimmed.range(of: " (", options: .backwards) else {
            return nil
        }
        let stateWithClosingParen = trimmed[stateStart.upperBound...]
        let state = String(stateWithClosingParen.dropLast())

        let beforeState = String(trimmed[..<stateStart.lowerBound])
        guard let udidStart = beforeState.range(of: " (", options: .backwards),
              beforeState.hasSuffix(")") else {
            return nil
        }

        let udidWithClosingParen = beforeState[udidStart.upperBound...]
        let udid = String(udidWithClosingParen.dropLast())
        let name = String(beforeState[..<udidStart.lowerBound])
        guard !name.isEmpty, !udid.isEmpty, !state.isEmpty else {
            return nil
        }

        return SimulatorDevice(name: name, udid: udid, state: state)
    }

    private func isAlreadyBooted(_ result: ProcessResult) -> Bool {
        let output = "\(result.stderr)\n\(result.stdout)"
        return output.localizedCaseInsensitiveContains("current state: Booted")
            || output.localizedCaseInsensitiveContains("device already booted")
    }

    private func nonEmptyOutput(from result: ProcessResult) -> String {
        let output = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return output.isEmpty ? "simctl command failed" : output
    }
}

private struct SimulatorDevice {
    let name: String
    let udid: String
    let state: String
}
