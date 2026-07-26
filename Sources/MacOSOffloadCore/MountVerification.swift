import Darwin
import Foundation

public enum MountVerificationMode: String, Codable, Sendable {
    case user
    case system
    case e2e
}

public struct MountVerificationOptions: Sendable {
    public let mode: MountVerificationMode
    public let scratchRoot: String
    public let home: String
    public let toolPath: String
    public let runtime: String?
    public let deviceType: String?
    public let keepArtifacts: Bool
    public let allowSystem: Bool
    public let allowSimDelete: Bool
    public let bootTimeoutSeconds: Int

    public init(
        mode: MountVerificationMode,
        scratchRoot: String,
        home: String,
        toolPath: String,
        runtime: String? = nil,
        deviceType: String? = nil,
        keepArtifacts: Bool = false,
        allowSystem: Bool = false,
        allowSimDelete: Bool = false,
        bootTimeoutSeconds: Int = 1800
    ) {
        self.mode = mode
        self.scratchRoot = scratchRoot
        self.home = home
        self.toolPath = toolPath
        self.runtime = runtime
        self.deviceType = deviceType
        self.keepArtifacts = keepArtifacts
        self.allowSystem = allowSystem
        self.allowSimDelete = allowSimDelete
        self.bootTimeoutSeconds = bootTimeoutSeconds
    }
}

public struct MountVerification {
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(runner: CommandRunning = SystemCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func run(options: MountVerificationOptions, event: (String) -> Void) throws {
        let scratchRoot = try validatedScratchRoot(options.scratchRoot)
        let runID = timestampWithPID()
        let root = "\(scratchRoot)/macos-offload-verify-\(runID)"
        var cleanupCommands: [[String]] = []
        var primaryError: Error?

        try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)

        event("==> verification mode: \(options.mode.rawValue)")
        event("==> scratch root: \(root)")

        do {
            switch options.mode {
            case .user:
                let home = "\(root)/home"
                try runTool(["mounts", "install", "--root", root, "--home", home, "--scope", "user", "--dry-run"], toolPath: options.toolPath, event: event)
                cleanupCommands.append(["mounts", "uninstall", "--root", root, "--home", home, "--scope", "user"])
                try runTool(["mounts", "install", "--root", root, "--home", home, "--scope", "user"], toolPath: options.toolPath, event: event)
                try runTool(["mounts", "status", "--root", root, "--home", home, "--scope", "user", "--json"], toolPath: options.toolPath, event: event)
                try runTool(cleanupCommands.removeLast(), toolPath: options.toolPath, event: event)

            case .system:
                throw CommandError(
                    "system mount verification is retired because CoreSimulator system paths must remain on the internal volume",
                    exitCode: 78
                )

            case .e2e:
                guard options.allowSimDelete else {
                    throw CommandError("e2e verification requires --allow-sim-delete or MACOS_OFFLOAD_VERIFY_ALLOW_SIM_DELETE=1", exitCode: 77)
                }
                cleanupCommands.append(["mounts", "uninstall", "--root", root, "--home", options.home, "--scope", "user", "--unload"])
                try runTool(["mounts", "install", "--root", root, "--home", options.home, "--scope", "user", "--load"], toolPath: options.toolPath, event: event)
                try runCommand("/usr/bin/xcrun", ["simctl", "list", "runtimes"], environment: defaultAppleToolEnvironment, event: event)
                try runCommand("/usr/bin/xcrun", ["simctl", "list", "devices", "available"], environment: defaultAppleToolEnvironment, event: event)
                try runCommand("/usr/bin/xcodebuild", ["-version"], environment: defaultAppleToolEnvironment, event: event)
                if let runtime = options.runtime, !runtime.isEmpty,
                   let deviceType = options.deviceType, !deviceType.isEmpty {
                    let name = "macos-offload-verify-\(runID)"
                    try runTool([
                        "sim", "recreate",
                        "--name", name,
                        "--device-type", deviceType,
                        "--runtime", runtime,
                        "--boot",
                        "--boot-timeout", "\(options.bootTimeoutSeconds)"
                    ], toolPath: options.toolPath, event: event)
                    try runCommand("/usr/bin/xcrun", ["simctl", "delete", name], environment: defaultAppleToolEnvironment, event: event)
                }
                try runTool(cleanupCommands.removeLast(), toolPath: options.toolPath, event: event)
            }
        } catch {
            primaryError = error
        }

        for command in cleanupCommands.reversed() {
            try? runTool(command, toolPath: options.toolPath, event: event)
        }

        if options.keepArtifacts {
            event("==> keeping verification artifacts at \(root)")
        } else {
            event("==> cleaning verification artifacts at \(root)")
            do {
                try fileManager.removeItem(atPath: root)
            } catch where primaryError == nil {
                primaryError = error
            } catch {
                event("cleanup warning: \(error.localizedDescription)")
            }
        }

        if let primaryError {
            throw primaryError
        }

        event("==> mount verification passed")
    }

    private var defaultAppleToolEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    private func runTool(_ arguments: [String], toolPath: String, event: (String) -> Void) throws {
        try runCommand(toolPath, arguments, environment: [:], event: event)
    }

    private func runCommand(_ executable: String, _ arguments: [String], environment: [String: String], event: (String) -> Void) throws {
        event("==> \(([executable] + arguments).map(\.shellQuoted).joined(separator: " "))")
        let result = try runner.run(executable, arguments: arguments, environment: environment)
        emit(result.stdout, event: event)
        emit(result.stderr, event: event)
        guard result.succeeded else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw CommandError(detail.isEmpty ? "verification command failed: \(executable)" : detail, exitCode: result.exitCode)
        }
    }

    private func emit(_ output: String, event: (String) -> Void) {
        guard !output.isEmpty else {
            return
        }
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).forEach(event)
    }

    private func validatedScratchRoot(_ path: String) throws -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let unsafe = ["/", "/Users", "/System", "/Library", "/Volumes"]
        guard !unsafe.contains(normalized) else {
            throw CommandError("refusing unsafe scratch root: \(normalized)", exitCode: 78)
        }
        return normalized
    }

    private func timestampWithPID() -> String {
        "\(timestamp())-\(getpid())"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
