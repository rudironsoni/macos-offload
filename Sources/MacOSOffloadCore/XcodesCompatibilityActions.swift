import Darwin
import Foundation

public struct XcodesCompatibilityActions {
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.environment = environment
    }

    public func installProfile(
        config: StorageConfig,
        toolPath: String,
        load: Bool,
        dryRun: Bool
    ) throws -> [String] {
        var actions = try MountActions(runner: runner, fileManager: fileManager).install(
            config: config,
            toolPath: toolPath,
            scope: .user,
            load: load,
            dryRun: dryRun
        )
        actions.append(contentsOf: try installEnvironment(directory: config.xcodeRoot, dryRun: dryRun))

        if !dryRun {
            let report = doctor(config: config, requireXcodes: false, strict: false)
            guard report.passed else {
                let detail = report.checks
                    .filter { $0.status == .fail }
                    .map(\.humanLine)
                    .joined(separator: "\n")
                throw CommandError(detail.isEmpty ? "xcodes compatibility profile verification failed" : detail)
            }
        }

        return actions
    }

    public func installEnvironment(directory: String, dryRun: Bool) throws -> [String] {
        let normalizedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let command = launchctlSetenvCommand(directory: normalizedDirectory)
        if !dryRun {
            try runOrThrow(command)
        }
        return [
            command.map(\.shellQuoted).joined(separator: " "),
            "export XCODES_DIRECTORY=\(normalizedDirectory.shellQuoted)"
        ]
    }

    public func doctor(config: StorageConfig, requireXcodes: Bool, strict: Bool) -> DoctorReport {
        var checks = [pathExists(config.xcodeRoot, label: "External Xcode applications directory exists")]
        checks.append(xcodesExecutableCheck(requireXcodes: requireXcodes))
        checks.append(xcodesDirectoryEnvironmentCheck(expectedDirectory: config.xcodeRoot, strict: strict))
        checks.append(xcodeSelectCheck(expectedDirectory: config.xcodeRoot, strict: strict))
        checks.append(appleToolCheck(executable: "/usr/bin/xcrun", arguments: ["-f", "xcodebuild"], label: "xcrun resolves xcodebuild"))
        checks.append(appleToolCheck(executable: "/usr/bin/xcodebuild", arguments: ["-version"], label: "xcodebuild responds"))
        checks.append(simctlRuntimeCheck())
        checks.append(appleToolCheck(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "available"], label: "simctl devices responds"))
        return DoctorReport(checks: checks)
    }

    private func pathExists(_ path: String, label: String) -> DoctorCheck {
        fileManager.fileExists(atPath: path)
            ? DoctorCheck(.pass, label, detail: path)
            : DoctorCheck(.fail, label.replacingOccurrences(of: " exists", with: " missing"), detail: path)
    }

    private func xcodesExecutableCheck(requireXcodes: Bool) -> DoctorCheck {
        if let path = findExecutable("xcodes") {
            return DoctorCheck(.pass, "xcodes executable is available", detail: path)
        }
        return DoctorCheck(
            requireXcodes ? .fail : .warn,
            requireXcodes ? "xcodes executable is missing" : "xcodes executable is optional",
            detail: "Install xcodes or omit --require-xcodes."
        )
    }

    private func xcodesDirectoryEnvironmentCheck(expectedDirectory: String, strict: Bool) -> DoctorCheck {
        guard let actual = environment["XCODES_DIRECTORY"], !actual.isEmpty else {
            return DoctorCheck(
                strict ? .fail : .warn,
                "XCODES_DIRECTORY is set for this process",
                detail: "Expected \(expectedDirectory)"
            )
        }

        let normalizedActual = URL(fileURLWithPath: actual).standardizedFileURL.path
        let normalizedExpected = URL(fileURLWithPath: expectedDirectory).standardizedFileURL.path
        if normalizedActual == normalizedExpected {
            return DoctorCheck(.pass, "XCODES_DIRECTORY points at managed Xcode apps", detail: normalizedExpected)
        }
        return DoctorCheck(.fail, "XCODES_DIRECTORY points at managed Xcode apps", detail: "\(normalizedActual), expected \(normalizedExpected)")
    }

    private func xcodeSelectCheck(expectedDirectory: String, strict: Bool) -> DoctorCheck {
        do {
            let result = try runner.run("/usr/bin/xcode-select", arguments: ["-p"], environment: appleToolEnvironment)
            guard result.succeeded else {
                return DoctorCheck(.fail, "xcode-select reports selected developer directory", detail: commandDetail(result))
            }

            let selected = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else {
                return DoctorCheck(.fail, "xcode-select reports selected developer directory")
            }

            let expectedPrefix = URL(fileURLWithPath: expectedDirectory).standardizedFileURL.path + "/"
            if selected.hasPrefix(expectedPrefix) {
                return DoctorCheck(.pass, "xcode-select uses managed Xcode apps", detail: selected)
            }

            return DoctorCheck(
                strict ? .fail : .warn,
                "xcode-select uses managed Xcode apps",
                detail: selected
            )
        } catch {
            return DoctorCheck(.fail, "xcode-select reports selected developer directory", detail: error.localizedDescription)
        }
    }

    private func appleToolCheck(executable: String, arguments: [String], label: String) -> DoctorCheck {
        do {
            let result = try runner.run(executable, arguments: arguments, environment: appleToolEnvironment)
            if result.succeeded {
                return DoctorCheck(.pass, label)
            }
            return DoctorCheck(.fail, label, detail: commandDetail(result))
        } catch {
            return DoctorCheck(.fail, label, detail: error.localizedDescription)
        }
    }

    private func simctlRuntimeCheck() -> DoctorCheck {
        do {
            let result = try runner.run("/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes"], environment: appleToolEnvironment)
            guard result.succeeded else {
                return DoctorCheck(.fail, "simctl runtimes responds", detail: commandDetail(result))
            }
            if result.stdout.contains("com.apple.CoreSimulator.SimRuntime") {
                return DoctorCheck(.pass, "simctl runtimes has available runtimes")
            }
            return DoctorCheck(.fail, "simctl runtimes has available runtimes", detail: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return DoctorCheck(.fail, "simctl runtimes responds", detail: error.localizedDescription)
        }
    }

    private func launchctlSetenvCommand(directory: String) -> [String] {
        if geteuid() == 0,
           let sudoUser = environment["SUDO_USER"],
           !sudoUser.isEmpty,
           let uid = userID(for: sudoUser) {
            return ["/bin/launchctl", "asuser", uid, "/bin/launchctl", "setenv", "XCODES_DIRECTORY", directory]
        }
        return ["/bin/launchctl", "setenv", "XCODES_DIRECTORY", directory]
    }

    private func userID(for user: String) -> String? {
        guard let result = try? runner.run("/usr/bin/id", arguments: ["-u", user], environment: [:]),
              result.succeeded else {
            return nil
        }
        let uid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uid.isEmpty ? nil : uid
    }

    private func runOrThrow(_ command: [String]) throws {
        guard let executable = command.first else {
            throw CommandError("empty command")
        }
        let result = try runner.run(executable, arguments: Array(command.dropFirst()), environment: [:])
        guard result.succeeded else {
            let detail = commandDetail(result)
            throw CommandError(detail.isEmpty ? "command failed: \(command.joined(separator: " "))" : detail)
        }
    }

    private func findExecutable(_ name: String) -> String? {
        guard let path = environment["PATH"] else {
            return nil
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
            let executable = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: executable) {
                return executable
            }
        }
        return nil
    }

    private func commandDetail(_ result: ProcessResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var appleToolEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}
