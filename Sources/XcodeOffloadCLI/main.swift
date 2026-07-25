import Foundation
import XcodeOffloadCore

@main
enum Main {
    static func main() {
        do {
            try CLI().run(Array(CommandLine.arguments.dropFirst()))
        } catch let exit as ExitRequested {
            Foundation.exit(exit.code)
        } catch let error as CommandError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            Foundation.exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            Foundation.exit(1)
        }
    }
}

struct CLI {
    func run(_ rawArguments: [String]) throws {
        var arguments = Arguments(rawArguments)
        let command = arguments.popCommand() ?? "help"

        switch command {
        case "help", "-h", "--help":
            printHelp()
        case "version", "--version":
            print(Version.current.displayString)
        case "doctor":
            try doctor(arguments: &arguments)
        case "repair":
            try repair(arguments: &arguments)
        case "init":
            try initialize(arguments: &arguments)
        case "mount":
            try mount(arguments: &arguments)
        case "unmount":
            try unmount(arguments: &arguments)
        case "install-shims":
            try installShims(arguments: &arguments)
        case "install-launchd":
            try installLaunchd(arguments: &arguments)
        case "uninstall-launchd":
            try uninstallLaunchd(arguments: &arguments)
        case "daemon":
            try daemon(arguments: &arguments)
        case "launchd":
            try launchd(arguments: &arguments)
        case "mounts":
            try mounts(arguments: &arguments)
        case "xcodes":
            try xcodes(arguments: &arguments)
        case "sim":
            try sim(arguments: &arguments)
        case "wrap-xcrun":
            try wrapper(arguments: arguments.remaining, kind: .xcrun)
        case "wrap-simctl":
            try wrapper(arguments: arguments.remaining, kind: .simctl)
        case "wrap-xcodebuild":
            try wrapper(arguments: arguments.remaining, kind: .xcodebuild)
        default:
            throw CommandError("unknown command: \(command)\n\nRun xcode-offload help.", exitCode: 64)
        }
    }

    private func doctor(arguments: inout Arguments) throws {
        let config = try makeConfig(arguments: &arguments)
        let json = arguments.popFlag("--json")
        let requireShims = arguments.popFlag("--require-shims")
        let skipSimctl = arguments.popFlag("--skip-simctl")
        let strict = arguments.popFlag("--strict")
        try arguments.rejectUnknown()

        let report = Doctor().run(config: config, requireShims: requireShims, validateSimctl: !skipSimctl, strict: strict)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            print()
        } else {
            for check in report.checks {
                print(check.humanLine)
            }

            if report.passed {
                print("OK xcode external storage doctor passed")
            } else {
                FileHandle.standardError.write(Data("FAIL xcode external storage doctor found \(report.failureCount) issue(s)\n".utf8))
            }
        }

        if !report.passed {
            throw ExitRequested(code: 1)
        }
    }

    private func repair(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let explicitShimDir = arguments.popOption("--shim-dir")
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let load = arguments.popFlag("--load")
        let installShims = arguments.popFlag("--install-shims")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments, explicitShimDir: explicitShimDir)
        try arguments.rejectUnknown()

        var plan = try MountActions().install(
            config: config,
            toolPath: toolPath,
            scope: scope,
            load: load,
            dryRun: dryRun
        )
        if installShims {
            plan.append(
                contentsOf: try StorageActions().installShims(
                    config: config,
                    toolPath: toolPath,
                    dryRun: dryRun
                )
            )
        }

        printActions(plan, verbose: verbose)
    }

    private func initialize(arguments: inout Arguments) throws {
        let config = try makeConfig(arguments: &arguments)
        let dryRun = arguments.popFlag("--dry-run")
        let createImages = !arguments.popFlag("--no-create-images")
        let verbose = arguments.popFlag("--verbose")
        try arguments.rejectUnknown()

        let actions = try StorageActions().initialize(config: config, createImages: createImages, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func mount(arguments: inout Arguments) throws {
        let kind = try mountKind(arguments.popCommand())
        let config = try makeConfig(arguments: &arguments)
        let dryRun = arguments.popFlag("--dry-run")
        let verbose = arguments.popFlag("--verbose")
        try arguments.rejectUnknown()

        let actions = try StorageActions().mount(kind, config: config, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func unmount(arguments: inout Arguments) throws {
        let kind = try mountKind(arguments.popCommand())
        let config = try makeConfig(arguments: &arguments)
        let dryRun = arguments.popFlag("--dry-run")
        let verbose = arguments.popFlag("--verbose")
        try arguments.rejectUnknown()

        let actions = try StorageActions().unmount(kind, config: config, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func installShims(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let explicitShimDir = arguments.popOption("--shim-dir")
        let dryRun = arguments.popFlag("--dry-run")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments, explicitShimDir: explicitShimDir)
        try arguments.rejectUnknown()

        let actions = try StorageActions().installShims(config: config, toolPath: toolPath, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func installLaunchd(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let load = arguments.popFlag("--load")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try MountActions().install(
            config: config,
            toolPath: toolPath,
            scope: scope,
            load: load,
            dryRun: dryRun
        )
        printActions(actions, verbose: verbose)
    }

    private func uninstallLaunchd(arguments: inout Arguments) throws {
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let unload = arguments.popFlag("--unload")
        let onReboot = arguments.popFlag("--on-reboot")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try MountActions().uninstall(
            config: config,
            scope: scope,
            unload: unload,
            onReboot: onReboot,
            dryRun: dryRun
        )
        printActions(actions, verbose: verbose)
    }

    private func daemon(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"

        switch subcommand {
        case "install":
            try installSystemLaunchd(arguments: &arguments)
        case "help", "-h", "--help":
            printDaemonHelp()
        default:
            throw CommandError("unknown daemon command: \(subcommand)", exitCode: 64)
        }
    }

    private func launchd(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"

        switch subcommand {
        case "install":
            try installSystemLaunchd(arguments: &arguments)
        case "help", "-h", "--help":
            printLaunchdHelp()
        default:
            throw CommandError("unknown launchd command: \(subcommand)", exitCode: 64)
        }
    }

    private func mounts(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"

        switch subcommand {
        case "install":
            try mountsInstall(arguments: &arguments)
        case "repair":
            try mountsRepair(arguments: &arguments)
        case "uninstall":
            try mountsUninstall(arguments: &arguments)
        case "status":
            try mountsStatus(arguments: &arguments)
        case "agent":
            try mountsAgent(arguments: &arguments)
        case "verify":
            try mountsVerify(arguments: &arguments)
        case "help", "-h", "--help":
            printMountsHelp()
        default:
            throw CommandError("unknown mounts command: \(subcommand)", exitCode: 64)
        }
    }

    private func mountsInstall(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let load = arguments.popFlag("--load")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try MountActions().install(config: config, toolPath: toolPath, scope: scope, load: load, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func mountsRepair(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let load = arguments.popFlag("--load")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try MountActions().repair(config: config, toolPath: toolPath, scope: scope, load: load, dryRun: dryRun)
        printActions(actions, verbose: verbose)
    }

    private func mountsUninstall(arguments: inout Arguments) throws {
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let dryRun = arguments.popFlag("--dry-run")
        let unload = arguments.popFlag("--unload")
        let onReboot = arguments.popFlag("--on-reboot")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try MountActions().uninstall(
            config: config,
            scope: scope,
            unload: unload,
            onReboot: onReboot,
            dryRun: dryRun
        )
        printActions(actions, verbose: verbose)
    }

    private func mountsStatus(arguments: inout Arguments) throws {
        let scope = try launchdScope(arguments.popOption("--scope") ?? "all")
        let json = arguments.popFlag("--json")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let report = MountActions().status(config: config, scope: scope)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            print()
        } else {
            MountStatusFormatter.messages(for: report).forEach { print($0) }
            if verbose {
                print()
                print("Checks:")
                report.checks.forEach { print("  \($0.humanLine)") }
            }
            if report.passed {
                print("OK xcode-offload mounts status passed")
            } else {
                FileHandle.standardError.write(Data("FAIL xcode-offload mounts status found \(report.failureCount) issue(s)\n".utf8))
            }
        }

        if !report.passed {
            throw ExitRequested(code: 1)
        }
    }

    private func mountsAgent(arguments: inout Arguments) throws {
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()
        try MountAgent().run(config: config)
    }

    private func mountsVerify(arguments: inout Arguments) throws {
        let modeValue = arguments.popOption("--mode") ?? "user"
        guard let mode = MountVerificationMode(rawValue: modeValue) else {
            throw CommandError("expected verification mode: user, system, or e2e", exitCode: 64)
        }

        let environment = ProcessInfo.processInfo.environment
        let scratchRoot = arguments.popOption("--scratch-root")
            ?? environment["XCODE_OFFLOAD_VERIFY_ROOT"]
        guard let scratchRoot, !scratchRoot.isEmpty else {
            throw CommandError("missing scratch root. Pass --scratch-root PATH or set XCODE_OFFLOAD_VERIFY_ROOT.", exitCode: 64)
        }

        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let home = arguments.popOption("--home") ?? environment["XCODE_OFFLOAD_VERIFY_HOME"] ?? verificationHome(environment: environment)
        let runtime = arguments.popOption("--runtime") ?? environment["XCODE_OFFLOAD_VERIFY_RUNTIME"]
        let deviceType = arguments.popOption("--device-type") ?? environment["XCODE_OFFLOAD_VERIFY_DEVICE_TYPE"]
        let keepArtifacts = arguments.popFlag("--keep-artifacts")
            || environmentFlag(environment["XCODE_OFFLOAD_VERIFY_KEEP_ARTIFACTS"])
        let allowSystem = arguments.popFlag("--allow-system")
            || environmentFlag(environment["XCODE_OFFLOAD_VERIFY_ALLOW_SYSTEM"])
        let allowSimDelete = arguments.popFlag("--allow-sim-delete")
            || environmentFlag(environment["XCODE_OFFLOAD_VERIFY_ALLOW_SIM_DELETE"])
        let bootTimeout = Int(arguments.popOption("--boot-timeout") ?? "1800") ?? 1800
        try arguments.rejectUnknown()

        let options = MountVerificationOptions(
            mode: mode,
            scratchRoot: scratchRoot,
            home: home,
            toolPath: toolPath,
            runtime: runtime,
            deviceType: deviceType,
            keepArtifacts: keepArtifacts,
            allowSystem: allowSystem,
            allowSimDelete: allowSimDelete,
            bootTimeoutSeconds: bootTimeout
        )

        try MountVerification().run(options: options) { event in
            print(event)
        }
    }

    private func xcodes(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"

        switch subcommand {
        case "install-profile":
            try xcodesInstallProfile(arguments: &arguments)
        case "doctor":
            try xcodesDoctor(arguments: &arguments)
        case "env":
            try xcodesEnv(arguments: &arguments)
        case "help", "-h", "--help":
            printXcodesHelp()
        default:
            throw CommandError("unknown xcodes command: \(subcommand)", exitCode: 64)
        }
    }

    private func xcodesInstallProfile(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let dryRun = arguments.popFlag("--dry-run")
        let load = arguments.popFlag("--load")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try XcodesCompatibilityActions().installProfile(
            config: config,
            toolPath: toolPath,
            load: load,
            dryRun: dryRun
        )
        printActions(actions, verbose: verbose)
    }

    private func xcodesDoctor(arguments: inout Arguments) throws {
        let json = arguments.popFlag("--json")
        let requireXcodes = arguments.popFlag("--require-xcodes")
        let strict = arguments.popFlag("--strict")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let report = XcodesCompatibilityActions().doctor(
            config: config,
            requireXcodes: requireXcodes,
            strict: strict
        )
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            print()
        } else {
            for check in report.checks {
                print(check.humanLine)
            }

            if report.passed {
                print("OK xcode-offload xcodes doctor passed")
            } else {
                FileHandle.standardError.write(Data("FAIL xcode-offload xcodes doctor found \(report.failureCount) issue(s)\n".utf8))
            }
        }

        if !report.passed {
            throw ExitRequested(code: 1)
        }
    }

    private func xcodesEnv(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"

        switch subcommand {
        case "install":
            let directory = arguments.popOption("--directory")
            let dryRun = arguments.popFlag("--dry-run")
            let verbose = arguments.popFlag("--verbose")
            let resolvedDirectory: String
            if let directory {
                try arguments.rejectUnknown()
                resolvedDirectory = directory
            } else {
                let config = try makeConfig(arguments: &arguments)
                try arguments.rejectUnknown()
                resolvedDirectory = config.mountXcodeAppsMount
            }

            let actions = try XcodesCompatibilityActions().installEnvironment(
                directory: resolvedDirectory,
                dryRun: dryRun
            )
            printActions(actions, verbose: verbose)
        case "help", "-h", "--help":
            printXcodesHelp()
        default:
            throw CommandError("unknown xcodes env command: \(subcommand)", exitCode: 64)
        }
    }

    private func installSystemLaunchd(arguments: inout Arguments) throws {
        let toolPath = arguments.popOption("--tool-path") ?? defaultToolPath()
        let dryRun = arguments.popFlag("--dry-run")
        let load = !arguments.popFlag("--no-load")
        let verbose = arguments.popFlag("--verbose")
        let config = try makeConfig(arguments: &arguments)
        try arguments.rejectUnknown()

        let actions = try StorageActions().installLaunchd(
            config: config,
            toolPath: toolPath,
            scope: .system,
            load: load,
            dryRun: dryRun
        )
        printActions(actions, verbose: verbose)
    }

    private func sim(arguments: inout Arguments) throws {
        let subcommand = arguments.popCommand() ?? "help"
        let simulator = SimulatorActions()

        switch subcommand {
        case "runtimes":
            try arguments.rejectUnknown()
            print(try simulator.listRuntimes(), terminator: "")
        case "devices":
            let availableOnly = !arguments.popFlag("--all")
            try arguments.rejectUnknown()
            print(try simulator.listDevices(availableOnly: availableOnly), terminator: "")
        case "recreate":
            let name = try arguments.requireOption("--name")
            let deviceType = try arguments.requireOption("--device-type")
            let runtime = try arguments.requireOption("--runtime")
            let boot = arguments.popFlag("--boot")
            let timeout = Int(arguments.popOption("--boot-timeout") ?? "1800") ?? 1800
            try arguments.rejectUnknown()

            let actions = try simulator.recreate(
                name: name,
                deviceType: deviceType,
                runtime: runtime,
                boot: boot,
                bootTimeoutSeconds: timeout
            )
            actions.forEach { print($0) }
        case "reset":
            let name = try arguments.requireOption("--name")
            let deviceType = try arguments.requireOption("--device-type")
            let runtime = try arguments.requireOption("--runtime")
            let boot = arguments.popFlag("--boot")
            let verify = arguments.popFlag("--verify")
            let timeout = Int(arguments.popOption("--boot-timeout") ?? "1800") ?? 1800
            let screenshot = arguments.popOption("--screenshot")
            try arguments.rejectUnknown()

            let actions = try simulator.reset(
                name: name,
                deviceType: deviceType,
                runtime: runtime,
                boot: boot,
                verify: verify,
                bootTimeoutSeconds: timeout,
                screenshotPath: screenshot
            )
            actions.forEach { print($0) }
        case "verify":
            let name = arguments.popOption("--name")
            let udid = arguments.popOption("--udid")
            let timeout = Int(arguments.popOption("--boot-timeout") ?? "1800") ?? 1800
            let screenshot = arguments.popOption("--screenshot")
            try arguments.rejectUnknown()

            let actions = try simulator.verify(
                name: name,
                udid: udid,
                bootTimeoutSeconds: timeout,
                screenshotPath: screenshot
            )
            actions.forEach { print($0) }
        case "open":
            let name = arguments.popOption("--name")
            let udid = arguments.popOption("--udid")
            let timeout = Int(arguments.popOption("--boot-timeout") ?? "1800") ?? 1800
            try arguments.rejectUnknown()

            let actions = try simulator.open(
                name: name,
                udid: udid,
                bootTimeoutSeconds: timeout
            )
            actions.forEach { print($0) }
        case "help":
            try arguments.rejectUnknown()
            printSimHelp()
        default:
            throw CommandError("unknown sim command: \(subcommand)", exitCode: 64)
        }
    }

    private func wrapper(arguments: [String], kind: WrapperKind) throws {
        var mutable = Arguments(arguments)
        let config = try makeConfig(arguments: &mutable)
        let dryRun = ProcessInfo.processInfo.environment["XCODE_SHIM_DRY_RUN"] == "1"
        let runner = WrapperRunner()

        switch kind {
        case .xcrun:
            try runner.runXcrun(arguments: mutable.remaining, config: config)
        case .simctl:
            try runner.runSimctl(arguments: mutable.remaining, config: config)
        case .xcodebuild:
            try runner.runXcodebuild(arguments: mutable.remaining, config: config, dryRun: dryRun)
        }
    }

    private func printActions(_ actions: [String], verbose: Bool) {
        let messages = ActionLogFormatter.messages(for: actions)
        if messages.isEmpty {
            print("OK no changes needed")
        } else {
            messages.forEach { print("==> \($0)") }
        }

        if verbose {
            if !messages.isEmpty {
                print()
            }
            print("Commands:")
            actions.forEach { print("  \($0)") }
        }
    }

    private func mountKind(_ value: String?) throws -> MountKind {
        guard let value, let kind = MountKind(rawValue: value) else {
            throw CommandError("expected mount kind: devices or caches", exitCode: 64)
        }
        return kind
    }

    private func launchdScope(_ value: String) throws -> LaunchdScope {
        guard let scope = LaunchdScope(rawValue: value) else {
            throw CommandError("expected launchd scope: user, system, or all", exitCode: 64)
        }
        return scope
    }

    private func makeConfig(arguments: inout Arguments, explicitShimDir: String? = nil) throws -> StorageConfig {
        let explicitRoot = arguments.popOption("--root")
        let explicitHome = arguments.popOption("--home")
        let root = try RootResolver.resolveRoot(explicitRoot: explicitRoot)
        return StorageConfig(root: root, home: explicitHome ?? NSHomeDirectory(), shimDirectory: explicitShimDir)
    }

    private func defaultToolPath() -> String {
        if let executablePath = Bundle.main.executablePath {
            return executablePath
        }

        let argument = CommandLine.arguments[0]
        if argument.hasPrefix("/") {
            return argument
        }

        return "\(FileManager.default.currentDirectoryPath)/\(argument)"
    }

    private func verificationHome(environment: [String: String]) -> String {
        if let sudoUser = environment["SUDO_USER"], !sudoUser.isEmpty {
            return "/Users/\(sudoUser)"
        }
        return NSHomeDirectory()
    }

    private func environmentFlag(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        switch value {
        case "1", "true", "TRUE", "yes", "YES":
            return true
        default:
            return false
        }
    }

    private func printHelp() {
        print(
            """
            xcode-offload manages external Xcode and CoreSimulator storage.

            Usage:
              xcode-offload doctor [--root PATH] [--require-shims] [--skip-simctl] [--strict] [--json]
              xcode-offload repair [--root PATH] [--home PATH] [--shim-dir PATH] [--scope user|system|all] [--install-shims] [--load] [--dry-run] [--verbose]
              xcode-offload init [--root PATH] [--dry-run] [--no-create-images] [--verbose]
              xcode-offload mount devices [--root PATH] [--dry-run] [--verbose]
              xcode-offload unmount devices [--root PATH] [--dry-run] [--verbose]
              xcode-offload install-shims [--root PATH] [--shim-dir PATH] [--dry-run] [--verbose]
              xcode-offload daemon install [--root PATH] [--home PATH] [--no-load] [--dry-run] [--verbose]
              xcode-offload launchd install [--root PATH] [--home PATH] [--no-load] [--dry-run] [--verbose]
              xcode-offload mounts install [--root PATH] [--home PATH] [--scope user|system|all] [--load] [--dry-run] [--verbose]
              xcode-offload mounts repair [--root PATH] [--home PATH] [--scope user|system|all] [--load] [--dry-run] [--verbose]
              xcode-offload mounts uninstall [--root PATH] [--home PATH] [--scope user|system|all] [--unload] [--on-reboot] [--dry-run] [--verbose]
              xcode-offload mounts status [--root PATH] [--home PATH] [--scope user|system|all] [--json] [--verbose]
              xcode-offload mounts verify --scratch-root PATH [--mode user|system|e2e] [--home PATH] [--runtime ID] [--device-type ID] [--keep-artifacts] [--allow-system] [--allow-sim-delete]
              xcode-offload xcodes install-profile [--root PATH] [--home PATH] [--load] [--dry-run] [--verbose]
              xcode-offload xcodes doctor [--root PATH] [--home PATH] [--require-xcodes] [--strict] [--json]
              xcode-offload xcodes env install [--root PATH] [--home PATH] [--directory PATH] [--dry-run] [--verbose]
              xcode-offload install-launchd [--root PATH] [--home PATH] [--scope user|system|all] [--load] [--dry-run] [--verbose]
              xcode-offload uninstall-launchd [--root PATH] [--home PATH] [--scope user|system|all] [--unload] [--dry-run] [--verbose]
              xcode-offload sim runtimes
              xcode-offload sim devices [--all]
              xcode-offload sim recreate --name NAME --device-type TYPE --runtime RUNTIME [--boot] [--boot-timeout SECONDS]
              xcode-offload sim reset --name NAME --device-type TYPE --runtime RUNTIME [--boot] [--verify] [--boot-timeout SECONDS] [--screenshot PATH]
              xcode-offload sim verify (--name NAME | --udid UDID) [--boot-timeout SECONDS] [--screenshot PATH]
              xcode-offload sim open (--name NAME | --udid UDID) [--boot-timeout SECONDS]
            """
        )
    }

    private func printDaemonHelp() {
        print(
            """
            Root CoreSimulator mount daemons are retired.

            Usage:
              xcode-offload daemon install [--root PATH] [--home PATH] [--no-load] [--dry-run] [--verbose]
            """
        )
    }

    private func printLaunchdHelp() {
        print(
            """
            Root CoreSimulator mount daemons are retired.

            Usage:
              xcode-offload launchd install [--root PATH] [--home PATH] [--no-load] [--dry-run] [--verbose]
            """
        )
    }

    private func printMountsHelp() {
        print(
            """
            xcode-offload mounts manages APFS sparsebundle mountpoints at Apple paths.

            Usage:
              xcode-offload mounts install [--root PATH] [--home PATH] [--scope user|system|all] [--load] [--dry-run] [--verbose]
              xcode-offload mounts repair [--root PATH] [--home PATH] [--scope user|system|all] [--load] [--dry-run] [--verbose]
              xcode-offload mounts uninstall [--root PATH] [--home PATH] [--scope user|system|all] [--unload] [--on-reboot] [--dry-run] [--verbose]
              xcode-offload mounts status [--root PATH] [--home PATH] [--scope user|system|all] [--json] [--verbose]
              xcode-offload mounts verify --scratch-root PATH [--mode user|system|e2e] [--home PATH] [--runtime ID] [--device-type ID] [--keep-artifacts] [--allow-system] [--allow-sim-delete]

            Only user-owned Devices, DerivedData, and Archives paths are mounted.
            CoreSimulator system paths remain on the internal volume.
            """
        )
    }

    private func printSimHelp() {
        print(
            """
            xcode-offload sim manages CoreSimulator devices through standard simctl.

            Usage:
              xcode-offload sim runtimes
              xcode-offload sim devices [--all]
              xcode-offload sim recreate --name NAME --device-type TYPE --runtime RUNTIME [--boot] [--boot-timeout SECONDS]
              xcode-offload sim reset --name NAME --device-type TYPE --runtime RUNTIME [--boot] [--verify] [--boot-timeout SECONDS] [--screenshot PATH]
              xcode-offload sim verify (--name NAME | --udid UDID) [--boot-timeout SECONDS] [--screenshot PATH]
              xcode-offload sim open (--name NAME | --udid UDID) [--boot-timeout SECONDS]
            """
        )
    }

    private func printXcodesHelp() {
        print(
            """
            xcode-offload xcodes configures transparent storage for xcodes and Apple tools.

            Usage:
              xcode-offload xcodes install-profile [--root PATH] [--home PATH] [--load] [--dry-run] [--verbose]
              xcode-offload xcodes doctor [--root PATH] [--home PATH] [--require-xcodes] [--strict] [--json]
              xcode-offload xcodes env install [--root PATH] [--home PATH] [--directory PATH] [--dry-run] [--verbose]

            The profile mounts user-owned APFS sparsebundles and sets XCODES_DIRECTORY to the external Xcode root.
            It does not install xcrun, simctl, or xcodebuild shims.
            """
        )
    }
}

enum WrapperKind {
    case xcrun
    case simctl
    case xcodebuild
}

struct Arguments {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    var remaining: [String] {
        values
    }

    mutating func popCommand() -> String? {
        guard !values.isEmpty else {
            return nil
        }
        return values.removeFirst()
    }

    mutating func popFlag(_ flag: String) -> Bool {
        guard let index = values.firstIndex(of: flag) else {
            return false
        }
        values.remove(at: index)
        return true
    }

    mutating func popOption(_ name: String) -> String? {
        if let index = values.firstIndex(of: name) {
            values.remove(at: index)
            guard index < values.count else {
                return nil
            }
            return values.remove(at: index)
        }

        let prefix = "\(name)="
        if let index = values.firstIndex(where: { $0.hasPrefix(prefix) }) {
            let value = String(values[index].dropFirst(prefix.count))
            values.remove(at: index)
            return value
        }

        return nil
    }

    mutating func requireOption(_ name: String) throws -> String {
        guard let value = popOption(name), !value.isEmpty else {
            throw CommandError("missing required option: \(name)", exitCode: 64)
        }
        return value
    }

    func rejectUnknown() throws {
        guard values.isEmpty else {
            throw CommandError("unknown argument(s): \(values.joined(separator: " "))", exitCode: 64)
        }
    }
}
