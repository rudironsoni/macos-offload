import Darwin
import Foundation

public enum CheckStatus: String, Codable, Sendable {
    case pass = "PASS"
    case warn = "WARN"
    case fail = "FAIL"
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let status: CheckStatus
    public let label: String
    public let detail: String?

    public init(_ status: CheckStatus, _ label: String, detail: String? = nil) {
        self.status = status
        self.label = label
        self.detail = detail
    }

    public var humanLine: String {
        if let detail, !detail.isEmpty {
            return "\(status.rawValue) \(label): \(detail)"
        }
        return "\(status.rawValue) \(label)"
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let checks: [DoctorCheck]

    public var failureCount: Int {
        checks.filter { $0.status == .fail }.count
    }

    public var warningCount: Int {
        checks.filter { $0.status == .warn }.count
    }

    public var passed: Bool {
        failureCount == 0
    }

    public init(checks: [DoctorCheck]) {
        self.checks = checks
    }
}

public struct Doctor {
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(runner: CommandRunning = SystemCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func run(
        config: StorageConfig,
        requireShims: Bool,
        validateSimctl: Bool,
        strict: Bool = false
    ) -> DoctorReport {
        var checks: [DoctorCheck] = []

        checks.append(pathExists(config.root, label: "External SSD exists"))
        checks.append(pathExists(config.xcodeRoot, label: "External Xcode root exists"))
        checks.append(pathExists(config.derivedData, label: "DerivedData root exists"))
        checks.append(pathExists(config.packageCache, label: "Package cache root exists"))
        checks.append(pathExists(config.tmp, label: "External tmp root exists"))
        checks.append(tmpWritable(config.tmp))
        checks.append(contentsOf: deviceMountChecks(config: config))

        if strict {
            checks.append(contentsOf: strictStorageChecks(config: config))
            checks.append(
                contentsOf: MountActions(runner: runner, fileManager: fileManager)
                    .mountChecks(config: config, scope: .all, includeLaunchd: true)
            )
        }

        if requireShims {
            checks.append(executableExists(config.xcrunShim, label: "xcrun wrapper exists"))
            checks.append(executableExists(config.simctlShim, label: "simctl wrapper exists"))
            checks.append(executableExists(config.xcodebuildShim, label: "xcodebuild wrapper exists"))
        }

        if validateSimctl {
            checks.append(simctlCheck(arguments: ["list", "runtimes"], label: "simctl runtimes responds"))
            checks.append(simctlCheck(arguments: ["list", "devices", "available"], label: "simctl devices responds"))
        }

        return DoctorReport(checks: checks)
    }

    private func pathExists(_ path: String, label: String) -> DoctorCheck {
        if fileManager.fileExists(atPath: path) {
            return DoctorCheck(.pass, label, detail: path)
        }
        return DoctorCheck(.fail, label.replacingOccurrences(of: " exists", with: " missing"), detail: path)
    }

    private func executableExists(_ path: String, label: String) -> DoctorCheck {
        if fileManager.isExecutableFile(atPath: path) {
            return DoctorCheck(.pass, label, detail: path)
        }
        return DoctorCheck(.fail, label.replacingOccurrences(of: " exists", with: " missing"), detail: path)
    }

    private func tmpWritable(_ path: String) -> DoctorCheck {
        guard fileManager.isWritableFile(atPath: path) else {
            return DoctorCheck(.fail, "External tmp is not writable", detail: path)
        }

        let probe = "\(path)/doctor.\(UUID().uuidString)"
        do {
            try "ok".write(toFile: probe, atomically: true, encoding: .utf8)
            try? fileManager.removeItem(atPath: probe)
            return DoctorCheck(.pass, "External tmp is writable")
        } catch {
            return DoctorCheck(.fail, "External tmp mktemp failed", detail: error.localizedDescription)
        }
    }

    private func deviceMountChecks(config: StorageConfig) -> [DoctorCheck] {
        guard let mountOutput = try? runner.run("/sbin/mount", arguments: [], environment: [:]),
              mountOutput.succeeded else {
            return [DoctorCheck(.fail, "Could not inspect mounts")]
        }

        guard let mountLine = TextParsers.mountLine(for: config.deviceMount, in: mountOutput.stdout) else {
            return [DoctorCheck(.fail, "CoreSimulator Devices is not mounted at \(config.deviceMount)")]
        }

        var checks = [DoctorCheck(.pass, "CoreSimulator Devices is mounted", detail: mountLine)]

        let hdiutilInfo = hdiutilInfo()
        if hdiutilInfo.contains(config.deviceStoreImage) {
            checks.append(DoctorCheck(.pass, "CoreSimulator Devices uses managed sparsebundle backend", detail: config.deviceStoreImage))
            return checks
        }

        let diskutilInfo = (try? runner.run("/usr/sbin/diskutil", arguments: ["info", config.deviceMount], environment: [:]))?.stdout ?? ""
        if TextParsers.volumeName(fromDiskutilInfo: diskutilInfo) == config.apfsDeviceVolumeName {
            if mountLine.contains("noowners") {
                checks.append(DoctorCheck(.fail, "CoreSimulator Devices APFS volume is mounted noowners"))
            } else {
                checks.append(
                    DoctorCheck(
                        .fail,
                        "CoreSimulator Devices uses unsupported direct APFS volume",
                        detail: "mount \(config.deviceStoreImage) at \(config.deviceMount)"
                    )
                )
            }
        } else {
            checks.append(
                DoctorCheck(
                    .fail,
                    "CoreSimulator Devices mount is not the managed sparsebundle backend",
                    detail: config.deviceStoreImage
                )
            )
        }

        return checks
    }

    private func strictStorageChecks(config: StorageConfig) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let hdiutilInfo = hdiutilInfo()
        checks.append(sparsebundleCheck(path: config.deviceStoreImage, label: "DeviceSet sparsebundle", hdiutilInfo: hdiutilInfo))
        checks.append(mountedAPFSCheck(mountPoint: config.deviceMount, label: "CoreSimulator Devices filesystem is APFS"))

        if hdiutilInfo.contains(config.deviceStoreImage) {
            checks.append(DoctorCheck(.pass, "DeviceSet sparsebundle is attached", detail: config.deviceStoreImage))
        } else {
            checks.append(DoctorCheck(.fail, "DeviceSet sparsebundle is not attached", detail: config.deviceStoreImage))
        }

        return checks
    }

    private func sparsebundleCheck(path: String, label: String, hdiutilInfo: String) -> DoctorCheck {
        guard fileManager.fileExists(atPath: path) else {
            return DoctorCheck(.fail, "\(label) missing", detail: path)
        }

        if hdiutilInfo.contains(path) {
            return DoctorCheck(.pass, "\(label) is readable", detail: "\(path) is already attached")
        }

        do {
            let result = try runner.run("/usr/bin/hdiutil", arguments: ["imageinfo", path], environment: [:])
            guard result.succeeded else {
                return DoctorCheck(.fail, "\(label) is not readable by hdiutil", detail: commandDetail(result))
            }

            let output = [result.stdout, result.stderr].joined(separator: "\n")
            if output.localizedCaseInsensitiveContains("sparse") || path.hasSuffix(".sparsebundle") {
                return DoctorCheck(.pass, "\(label) is readable", detail: path)
            }
            return DoctorCheck(.fail, "\(label) is not reported as a sparse image", detail: path)
        } catch {
            return DoctorCheck(.fail, "\(label) imageinfo failed", detail: error.localizedDescription)
        }
    }

    private func mountedAPFSCheck(mountPoint: String, label: String) -> DoctorCheck {
        do {
            let result = try runner.run("/usr/sbin/diskutil", arguments: ["info", mountPoint], environment: [:])
            guard result.succeeded else {
                return DoctorCheck(.fail, label, detail: commandDetail(result))
            }

            if TextParsers.isAPFS(fromDiskutilInfo: result.stdout) {
                return DoctorCheck(.pass, label)
            }
            return DoctorCheck(.fail, label, detail: "diskutil did not report APFS for \(mountPoint)")
        } catch {
            return DoctorCheck(.fail, label, detail: error.localizedDescription)
        }
    }

    private func plistLint(path: String, label: String) -> DoctorCheck {
        guard fileManager.fileExists(atPath: path) else {
            return DoctorCheck(.fail, label, detail: "missing \(path)")
        }

        do {
            let result = try runner.run("/usr/bin/plutil", arguments: ["-lint", path], environment: [:])
            if result.succeeded {
                return DoctorCheck(.pass, label, detail: path)
            }
            return DoctorCheck(.fail, label, detail: commandDetail(result))
        } catch {
            return DoctorCheck(.fail, label, detail: error.localizedDescription)
        }
    }

    private func launchctlCheck(domain: String, label: String, displayName: String) -> DoctorCheck {
        do {
            let result = try runner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"], environment: [:])
            guard result.succeeded else {
                return DoctorCheck(.fail, "\(displayName) is loaded", detail: commandDetail(result))
            }

            if let status = TextParsers.launchctlLastExitStatus(from: result.stdout) {
                if status == 0 {
                    return DoctorCheck(.pass, "\(displayName) last exit status is 0")
                }
                return DoctorCheck(.fail, "\(displayName) last exit status is \(status)")
            }

            return DoctorCheck(.pass, "\(displayName) is loaded")
        } catch {
            return DoctorCheck(.fail, "\(displayName) is loaded", detail: error.localizedDescription)
        }
    }

    private func hdiutilInfo() -> String {
        (try? runner.run("/usr/bin/hdiutil", arguments: ["info"], environment: [:]))?.stdout ?? ""
    }

    private func commandDetail(_ result: ProcessResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func simctlCheck(arguments: [String], label: String) -> DoctorCheck {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let environment = ["PATH": "\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(path)"]

        do {
            let result = try runner.run("/usr/bin/xcrun", arguments: ["simctl"] + arguments, environment: environment)
            if result.succeeded {
                if arguments == ["list", "runtimes"],
                   !result.stdout.contains("com.apple.CoreSimulator.SimRuntime") {
                    return DoctorCheck(.fail, "simctl runtimes has available runtimes", detail: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return DoctorCheck(.pass, label)
            }

            let detail = [result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n")
            return DoctorCheck(.fail, label, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return DoctorCheck(.fail, label, detail: error.localizedDescription)
        }
    }
}
