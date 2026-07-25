import Darwin
import Foundation

public struct MountStatusReport: Codable, Equatable, Sendable {
    public let checks: [DoctorCheck]
    public let lifecycle: MountLifecycleSnapshot?

    public var passed: Bool {
        checks.allSatisfy { $0.status != .fail }
            && lifecycle.map { $0.state == .ready } != false
    }

    public var failureCount: Int {
        checks.filter { $0.status == .fail }.count
            + (lifecycle.map { $0.state == .ready ? 0 : 1 } ?? 0)
    }

    public init(checks: [DoctorCheck], lifecycle: MountLifecycleSnapshot? = nil) {
        self.checks = checks
        self.lifecycle = lifecycle
    }
}

public struct MountActions {
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(runner: CommandRunning = SystemCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func install(config: StorageConfig, toolPath: String, scope: LaunchdScope, load: Bool, dryRun: Bool) throws -> [String] {
        if scope == .system {
            throw CommandError(
                "system mounts are retired because CoreSimulator system paths must remain on the internal volume",
                exitCode: 78
            )
        }
        if scope == .all, legacySystemIsActive(config: config) {
            throw CommandError(
                "legacy system mounts are still active; retire them with mounts uninstall --scope system --unload --on-reboot, then restart",
                exitCode: 78
            )
        }
        try preflight(scope: scope, dryRun: dryRun)
        var actions: [String] = []
        actions.append(contentsOf: try reconcile(config: config, dryRun: dryRun, createImages: true))
        actions.append(contentsOf: try installLaunchd(config: config, toolPath: toolPath, scope: scope, load: load, dryRun: dryRun))
        return actions
    }

    public func repair(config: StorageConfig, toolPath: String, scope: LaunchdScope, load: Bool, dryRun: Bool) throws -> [String] {
        try install(config: config, toolPath: toolPath, scope: scope, load: load, dryRun: dryRun)
    }

    public func reconcile(
        config: StorageConfig,
        dryRun: Bool,
        createImages: Bool = false
    ) throws -> [String] {
        if dryRun {
            return try reconcileUnlocked(
                config: config,
                dryRun: true,
                createImages: createImages
            )
        }

        return try MountLifecycleFiles.withLock(config: config, fileManager: fileManager) {
            do {
                let volumeUUID = try verifyRootIdentity(config: config)
                try writeLifecycleSnapshot(
                    snapshot: MountLifecycleSnapshot(
                        state: .reconciling,
                        rootPath: config.root,
                        volumeUUID: volumeUUID,
                        mountedIDs: []
                    ),
                    config: config
                )
                let actions = try reconcileUnlocked(
                    config: config,
                    dryRun: false,
                    createImages: createImages
                )
                let mountedIDs = try verifiedMountedIDs(config: config)
                try writeLifecycleSnapshot(
                    snapshot: MountLifecycleSnapshot(
                        state: .ready,
                        rootPath: config.root,
                        volumeUUID: volumeUUID,
                        mountedIDs: mountedIDs
                    ),
                    config: config
                )
                return actions
            } catch {
                let message = (error as? CommandError)?.message ?? error.localizedDescription
                let state: MountLifecycleState
                if message.contains("not available") {
                    state = .waitingForVolume
                } else if message.contains("UUID") {
                    state = .blockedWrongVolume
                } else if message.contains("different backend") {
                    state = .blockedWrongBackend
                } else {
                    state = .failed
                }
                try? writeLifecycleSnapshot(
                    snapshot: MountLifecycleSnapshot(
                        state: state,
                        rootPath: config.root,
                        volumeUUID: nil,
                        mountedIDs: [],
                        lastError: message
                    ),
                    config: config
                )
                throw error
            }
        }
    }

    public func uninstall(
        config: StorageConfig,
        scope: LaunchdScope,
        unload: Bool,
        onReboot: Bool = false,
        dryRun: Bool
    ) throws -> [String] {
        if scope == .system || scope == .all {
            guard onReboot else {
                throw CommandError(
                    "system mounts must be retired with --on-reboot so active CoreSimulator runtime mounts are never detached",
                    exitCode: 78
                )
            }
            if !dryRun, geteuid() != 0 {
                throw CommandError("system mount retirement requires root", exitCode: 77)
            }
        }
        var actions: [String] = []

        if scope == .user || scope == .all {
            if unload {
                let uid = getuid()
                actions.append("launchctl bootout gui/\(uid) \(config.mountUserLaunchAgentPath.shellQuoted) || true")
                if !dryRun {
                    _ = try? runner.run("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", config.mountUserLaunchAgentPath], environment: [:])
                }
            }
            actions.append("rm -f \(config.mountUserLaunchAgentPath.shellQuoted)")
            if !dryRun {
                try? fileManager.removeItem(atPath: config.mountUserLaunchAgentPath)
            }
        }

        if scope == .system || scope == .all {
            if unload {
                actions.append("launchctl bootout system \(config.mountSystemLaunchDaemonPath.shellQuoted) || true")
                actions.append("launchctl bootout system \(config.systemLaunchDaemonPath.shellQuoted) || true")
                if !dryRun {
                    _ = try? runner.run("/bin/launchctl", arguments: ["bootout", "system", config.mountSystemLaunchDaemonPath], environment: [:])
                    _ = try? runner.run("/bin/launchctl", arguments: ["bootout", "system", config.systemLaunchDaemonPath], environment: [:])
                }
            }
            actions.append("rm -f \(config.mountSystemLaunchDaemonPath.shellQuoted)")
            actions.append("rm -f \(config.mountSystemHelperPath.shellQuoted)")
            actions.append("rm -f \(config.systemLaunchDaemonPath.shellQuoted)")
            actions.append("rm -f \(config.cacheHelperPath.shellQuoted)")
            actions.append("restart required to release retired system sparsebundles safely")
            if !dryRun {
                try? fileManager.removeItem(atPath: config.mountSystemLaunchDaemonPath)
                try? fileManager.removeItem(atPath: config.mountSystemHelperPath)
                try? fileManager.removeItem(atPath: config.systemLaunchDaemonPath)
                try? fileManager.removeItem(atPath: config.cacheHelperPath)
            }
        }

        if scope == .user || scope == .all {
            for managedMount in ManagedMounts.user(config: config) {
                actions.append(contentsOf: try unmount(managedMount: managedMount, dryRun: dryRun))
            }
        }

        return actions
    }

    public func status(config: StorageConfig, scope: LaunchdScope) -> MountStatusReport {
        MountStatusReport(
            checks: mountChecks(config: config, scope: scope, includeLaunchd: true),
            lifecycle: MountLifecycleFiles.loadSnapshot(config: config, fileManager: fileManager)
        )
    }

    public func mountChecks(config: StorageConfig, scope: LaunchdScope, includeLaunchd: Bool) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let mounts = ManagedMounts.matching(scope: scope, config: config)
        let mountOutput = (try? runner.run("/sbin/mount", arguments: [], environment: [:]))?.stdout ?? ""
        let hdiutilOutput = (try? runner.run("/usr/bin/hdiutil", arguments: ["info"], environment: [:]))?.stdout ?? ""

        for managedMount in mounts {
            checks.append(symlinkCheck(managedMount))
            checks.append(imageCheck(managedMount))
            checks.append(mountCheck(managedMount, mountOutput: mountOutput))
            checks.append(apfsCheck(managedMount))
            checks.append(ownersCheck(managedMount))
            checks.append(backendCheck(managedMount, hdiutilOutput: hdiutilOutput))
        }

        if includeLaunchd {
            if scope == .user || scope == .all {
                checks.append(pathExists(config.mountUserLaunchAgentPath, label: "Mount user LaunchAgent exists"))
            }
            if scope == .system || scope == .all {
                checks.append(contentsOf: legacySystemChecks(config: config, hdiutilOutput: hdiutilOutput))
            }
        }

        return checks
    }

    private func legacySystemChecks(config: StorageConfig, hdiutilOutput: String) -> [DoctorCheck] {
        var checks = [
            pathAbsent(config.mountSystemLaunchDaemonPath, label: "Legacy mount system LaunchDaemon is absent"),
            pathAbsent(config.mountSystemHelperPath, label: "Legacy mount system helper is absent"),
            pathAbsent(config.systemLaunchDaemonPath, label: "Legacy cache LaunchDaemon is absent"),
            pathAbsent(config.cacheHelperPath, label: "Legacy cache helper is absent")
        ]
        for managedMount in ManagedMounts.legacySystem(config: config) {
            let attached = TextParsers.hdiutilInfoContains(
                imagePath: managedMount.imagePath,
                mountPoint: managedMount.mountPoint,
                in: hdiutilOutput
            )
            checks.append(
                attached
                    ? DoctorCheck(
                        .fail,
                        "Legacy system mount \(managedMount.id) is detached",
                        detail: "restart after retiring the system LaunchDaemons"
                    )
                    : DoctorCheck(.pass, "Legacy system mount \(managedMount.id) is detached")
            )
        }
        return checks
    }

    private func legacySystemIsActive(config: StorageConfig) -> Bool {
        let paths = [
            config.mountSystemLaunchDaemonPath,
            config.mountSystemHelperPath,
            config.systemLaunchDaemonPath,
            config.cacheHelperPath
        ]
        if paths.contains(where: fileManager.fileExists(atPath:)) {
            return true
        }
        let hdiutilOutput = (try? runner.run(
            "/usr/bin/hdiutil",
            arguments: ["info"],
            environment: [:],
            timeoutSeconds: 30
        ))?.stdout ?? ""
        return ManagedMounts.legacySystem(config: config).contains { managedMount in
            TextParsers.hdiutilInfoContains(
                imagePath: managedMount.imagePath,
                mountPoint: managedMount.mountPoint,
                in: hdiutilOutput
            )
        }
    }

    private func pathAbsent(_ path: String, label: String) -> DoctorCheck {
        fileManager.fileExists(atPath: path)
            ? DoctorCheck(.fail, label, detail: path)
            : DoctorCheck(.pass, label, detail: path)
    }

    private func createSparsebundles(mounts: [ManagedMount], dryRun: Bool) throws -> [String] {
        var actions: [String] = []
        for managedMount in mounts {
            let parent = URL(fileURLWithPath: managedMount.imagePath).deletingLastPathComponent().path
            actions.append("mkdir -p \(parent.shellQuoted)")
            if !dryRun {
                try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            if !fileManager.fileExists(atPath: managedMount.imagePath) {
                let command = hdiutilCreateCommand(managedMount)
                actions.append(command.map(\.shellQuoted).joined(separator: " "))
                if !dryRun {
                    try runOrThrow(command)
                }
            }

            if managedMount.preparation == .coreSimulatorImages {
                actions.append(contentsOf: try detachStaleAttachments(for: managedMount, dryRun: dryRun))
                actions.append(contentsOf: try prepareImagesSparsebundle(managedMount, dryRun: dryRun))
            }
        }
        return actions
    }

    private func reconcileUnlocked(
        config: StorageConfig,
        dryRun: Bool,
        createImages: Bool
    ) throws -> [String] {
        let mounts = ManagedMounts.user(config: config)
        var actions: [String] = []
        if createImages {
            actions.append(contentsOf: try createSparsebundles(mounts: mounts, dryRun: dryRun))
        } else {
            for managedMount in mounts where !fileManager.fileExists(atPath: managedMount.imagePath) {
                throw CommandError("missing sparsebundle: \(managedMount.imagePath)", exitCode: 78)
            }
        }
        actions.append(
            contentsOf: try mount(
                mounts: mounts,
                config: config,
                allowBackup: createImages,
                dryRun: dryRun
            )
        )
        return actions
    }

    private func verifyRootIdentity(config: StorageConfig) throws -> String {
        guard fileManager.fileExists(atPath: config.root) else {
            throw CommandError("configured external root is not available: \(config.root)", exitCode: 69)
        }

        let result = try runner.run(
            "/usr/sbin/diskutil",
            arguments: ["info", config.root],
            environment: [:],
            timeoutSeconds: 30
        )
        let detectedUUID = TextParsers.volumeUUID(fromDiskutilInfo: result.stdout)
            ?? (config.root.hasPrefix("/Volumes/") ? nil : "local:\(config.root)")
        guard result.succeeded, let detectedUUID, !detectedUUID.isEmpty else {
            throw CommandError("cannot determine external volume UUID for \(config.root)", exitCode: 69)
        }

        if let expected = try MountLifecycleFiles.loadConfiguration(config: config, fileManager: fileManager) {
            guard expected.schemaVersion == 1 else {
                throw CommandError(
                    "unsupported mount configuration schema version: \(expected.schemaVersion)",
                    exitCode: 78
                )
            }
            guard expected.rootPath == config.root else {
                throw CommandError(
                    "configured external root mismatch: expected \(expected.rootPath), found \(config.root)",
                    exitCode: 78
                )
            }
            guard expected.volumeUUID == detectedUUID else {
                throw CommandError(
                    "external volume UUID mismatch at \(config.root): expected \(expected.volumeUUID), found \(detectedUUID)",
                    exitCode: 78
                )
            }
            return detectedUUID
        }

        try MountLifecycleFiles.write(
            configuration: MountConfiguration(rootPath: config.root, volumeUUID: detectedUUID),
            config: config,
            fileManager: fileManager
        )
        return detectedUUID
    }

    private func verifiedMountedIDs(config: StorageConfig) throws -> [String] {
        let mountResult = try runner.run(
            "/sbin/mount",
            arguments: [],
            environment: [:],
            timeoutSeconds: 30
        )
        let hdiutilResult = try runner.run(
            "/usr/bin/hdiutil",
            arguments: ["info"],
            environment: [:],
            timeoutSeconds: 30
        )
        guard mountResult.succeeded, hdiutilResult.succeeded else {
            throw CommandError("cannot verify reconciled mount state", exitCode: 69)
        }

        var mountedIDs: [String] = []
        for managedMount in ManagedMounts.user(config: config) {
            guard TextParsers.mountLine(for: managedMount.mountPoint, in: mountResult.stdout) != nil else {
                throw CommandError("mount did not appear after reconciliation: \(managedMount.mountPoint)", exitCode: 69)
            }
            guard TextParsers.hdiutilInfoContains(
                imagePath: managedMount.imagePath,
                mountPoint: managedMount.mountPoint,
                in: hdiutilResult.stdout
            ) else {
                throw CommandError(
                    "mountpoint is mounted from a different backend: \(managedMount.mountPoint)",
                    exitCode: 78
                )
            }
            mountedIDs.append(managedMount.id)
        }
        return mountedIDs
    }

    private func writeLifecycleSnapshot(
        snapshot: MountLifecycleSnapshot,
        config: StorageConfig
    ) throws {
        if let previous = MountLifecycleFiles.loadSnapshot(config: config, fileManager: fileManager),
           previous.state == snapshot.state,
           previous.rootPath == snapshot.rootPath,
           previous.volumeUUID == snapshot.volumeUUID,
           previous.mountedIDs == snapshot.mountedIDs,
           previous.lastError == snapshot.lastError {
            return
        }
        try MountLifecycleFiles.write(
            snapshot: snapshot,
            config: config,
            fileManager: fileManager
        )
    }

    private func mount(
        mounts: [ManagedMount],
        config: StorageConfig,
        allowBackup: Bool,
        dryRun: Bool
    ) throws -> [String] {
        var actions: [String] = []
        for managedMount in mounts {
            actions.append(
                contentsOf: try mount(
                    managedMount: managedMount,
                    backupRoot: backupRoot(for: managedMount, config: config),
                    allowBackup: allowBackup,
                    dryRun: dryRun
                )
            )
        }
        return actions
    }

    private func mount(
        managedMount: ManagedMount,
        backupRoot: String,
        allowBackup: Bool,
        dryRun: Bool
    ) throws -> [String] {
        try rejectSymlink(managedMount.mountPoint)

        if isMounted(managedMount.mountPoint) {
            if isMountedFromConfiguredBackend(managedMount) {
                return ["already mounted \(managedMount.mountPoint.shellQuoted)"]
            }
            throw CommandError("mountpoint is already mounted from a different backend: \(managedMount.mountPoint)", exitCode: 78)
        }
        try rejectNestedMounts(under: managedMount.mountPoint)

        guard dryRun || fileManager.fileExists(atPath: managedMount.imagePath) else {
            throw CommandError("missing sparsebundle: \(managedMount.imagePath)", exitCode: 78)
        }

        var actions = try detachStaleAttachments(for: managedMount, dryRun: dryRun)
        actions.append(
            contentsOf: try prepareMountpoint(
                managedMount,
                backupRoot: backupRoot,
                allowBackup: allowBackup,
                dryRun: dryRun
            )
        )
        let command = [
            "/usr/bin/hdiutil",
            "attach",
            managedMount.imagePath,
            "-mountpoint",
            managedMount.mountPoint,
            "-nobrowse",
            "-owners",
            "on"
        ]
        actions.append(command.map(\.shellQuoted).joined(separator: " "))
        if !dryRun {
            try runOrThrow(command)
        }
        return actions
    }

    private func detachStaleAttachments(for managedMount: ManagedMount, dryRun: Bool) throws -> [String] {
        guard let result = try? runner.run("/usr/bin/hdiutil", arguments: ["info"], environment: [:]), result.succeeded else {
            return []
        }
        guard !TextParsers.hdiutilInfoContains(
            imagePath: managedMount.imagePath,
            mountPoint: managedMount.mountPoint,
            in: result.stdout
        ) else {
            return []
        }

        let devices = TextParsers.hdiutilAttachedDevices(imagePath: managedMount.imagePath, in: result.stdout)
        var actions: [String] = []
        for device in devices {
            let command = ["/usr/bin/hdiutil", "detach", device]
            actions.append(command.map(\.shellQuoted).joined(separator: " "))
            if !dryRun {
                try runOrThrow(command)
            }
        }
        return actions
    }

    private func unmount(managedMount: ManagedMount, dryRun: Bool) throws -> [String] {
        if !isMounted(managedMount.mountPoint) {
            return ["not mounted \(managedMount.mountPoint.shellQuoted)"]
        }

        if !isMountedFromConfiguredBackend(managedMount) {
            throw CommandError("refusing to detach mountpoint from a different backend: \(managedMount.mountPoint)", exitCode: 78)
        }

        let command = ["/usr/bin/hdiutil", "detach", managedMount.mountPoint]
        if !dryRun {
            try runOrThrow(command)
        }
        return [command.map(\.shellQuoted).joined(separator: " ")]
    }

    private func prepareMountpoint(
        _ managedMount: ManagedMount,
        backupRoot: String,
        allowBackup: Bool,
        dryRun: Bool
    ) throws -> [String] {
        let parent = URL(fileURLWithPath: managedMount.mountPoint).deletingLastPathComponent().path
        var actions = ["mkdir -p \(parent.shellQuoted)"]
        if !dryRun {
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: managedMount.mountPoint) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: managedMount.mountPoint)) ?? []
            if !contents.isEmpty {
                guard allowBackup else {
                    throw CommandError(
                        "refusing runtime reconciliation because mountpoint contains data: \(managedMount.mountPoint)",
                        exitCode: 78
                    )
                }
                let backupDirectory = "\(backupRoot)/\(timestamp())/\(managedMount.id)"
                let manifest = "\(backupDirectory).manifest"
                actions.append("mkdir -p \(URL(fileURLWithPath: backupDirectory).deletingLastPathComponent().path.shellQuoted)")
                actions.append("write \(manifest.shellQuoted)")
                actions.append("mv \(managedMount.mountPoint.shellQuoted) \(backupDirectory.shellQuoted)")
                if !dryRun {
                    try fileManager.createDirectory(
                        atPath: URL(fileURLWithPath: backupDirectory).deletingLastPathComponent().path,
                        withIntermediateDirectories: true
                    )
                    let body = "id=\(managedMount.id)\nmountPoint=\(managedMount.mountPoint)\nbackup=\(backupDirectory)\n"
                    try body.write(toFile: manifest, atomically: true, encoding: .utf8)
                    try fileManager.moveItem(atPath: managedMount.mountPoint, toPath: backupDirectory)
                }
            }
        }

        actions.append("mkdir -p \(managedMount.mountPoint.shellQuoted)")
        if managedMount.requiredOwner == "root:wheel" {
            actions.append("chown root:wheel \(managedMount.mountPoint.shellQuoted) || true")
        }
        actions.append("chmod \(managedMount.requiredMode) \(managedMount.mountPoint.shellQuoted) || true")

        if !dryRun {
            try fileManager.createDirectory(atPath: managedMount.mountPoint, withIntermediateDirectories: true)
            if managedMount.requiredOwner == "root:wheel" {
                _ = try? runner.run("/usr/sbin/chown", arguments: ["root:wheel", managedMount.mountPoint], environment: [:])
            }
            _ = try? runner.run("/bin/chmod", arguments: [managedMount.requiredMode, managedMount.mountPoint], environment: [:])
        }

        return actions
    }

    private func prepareImagesSparsebundle(_ managedMount: ManagedMount, dryRun: Bool) throws -> [String] {
        let tempMount = "\(NSTemporaryDirectory())xcode-offload-images-\(UUID().uuidString)"
        let attach = ["/usr/bin/hdiutil", "attach", managedMount.imagePath, "-mountpoint", tempMount, "-nobrowse", "-owners", "on"]
        let detach = ["/usr/bin/hdiutil", "detach", tempMount]
        let actions = [
            "mkdir -p \(tempMount.shellQuoted)",
            attach.map(\.shellQuoted).joined(separator: " "),
            "mkdir -p \(tempMount.shellQuoted)/mnt",
            "chmod 1777 \(tempMount.shellQuoted)/mnt",
            detach.map(\.shellQuoted).joined(separator: " ")
        ]

        if isMounted(managedMount.mountPoint) {
            if !isMountedFromConfiguredBackend(managedMount) {
                throw CommandError("mountpoint is already mounted from a different backend: \(managedMount.mountPoint)", exitCode: 78)
            }
            return ["already prepared \(managedMount.mountPoint.shellQuoted)"]
        }

        if dryRun || !fileManager.fileExists(atPath: managedMount.imagePath) {
            return actions
        }

        try fileManager.createDirectory(atPath: tempMount, withIntermediateDirectories: true)
        var attached = false
        defer {
            if attached {
                try? runOrThrow(detach)
            }
            try? fileManager.removeItem(atPath: tempMount)
        }
        try runOrThrow(attach)
        attached = true
        try fileManager.createDirectory(atPath: "\(tempMount)/mnt", withIntermediateDirectories: true)
        try runOrThrow(["/bin/chmod", "1777", "\(tempMount)/mnt"])
        try runOrThrow(detach)
        attached = false
        return actions
    }

    private func installLaunchd(config: StorageConfig, toolPath: String, scope: LaunchdScope, load: Bool, dryRun: Bool) throws -> [String] {
        let templates = MountLaunchdTemplates(config: config, toolPath: toolPath)
        var actions: [String] = []

        if scope == .user || scope == .all {
            let directory = URL(fileURLWithPath: config.mountUserLaunchAgentPath).deletingLastPathComponent().path
            actions.append("mkdir -p \(directory.shellQuoted)")
            actions.append("write \(config.mountUserLaunchAgentPath.shellQuoted)")
            actions.append("chmod 0644 \(config.mountUserLaunchAgentPath.shellQuoted)")
            if !dryRun {
                try validatePlist(templates.userAgentPlist, name: "mount user LaunchAgent")
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try templates.userAgentPlist.write(toFile: config.mountUserLaunchAgentPath, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.mountUserLaunchAgentPath)
            }

            if load {
                let uid = getuid()
                actions.append("launchctl bootout gui/\(uid) \(config.mountUserLaunchAgentPath.shellQuoted) || true")
                actions.append("launchctl bootstrap gui/\(uid) \(config.mountUserLaunchAgentPath.shellQuoted)")
                if !dryRun {
                    _ = try? runner.run("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", config.mountUserLaunchAgentPath], environment: [:])
                    try runOrThrow(["/bin/launchctl", "bootstrap", "gui/\(uid)", config.mountUserLaunchAgentPath])
                }
            }
        }

        return actions
    }

    private func symlinkCheck(_ managedMount: ManagedMount) -> DoctorCheck {
        if isSymlink(managedMount.mountPoint) {
            return DoctorCheck(.fail, "Mount \(managedMount.id) mountpoint is not a symlink", detail: managedMount.mountPoint)
        }
        return DoctorCheck(.pass, "Mount \(managedMount.id) mountpoint is not a symlink", detail: managedMount.mountPoint)
    }

    private func imageCheck(_ managedMount: ManagedMount) -> DoctorCheck {
        if fileManager.fileExists(atPath: managedMount.imagePath) {
            return DoctorCheck(.pass, "Mount \(managedMount.id) sparsebundle exists", detail: managedMount.imagePath)
        }
        return DoctorCheck(.fail, "Mount \(managedMount.id) sparsebundle missing", detail: managedMount.imagePath)
    }

    private func mountCheck(_ managedMount: ManagedMount, mountOutput: String) -> DoctorCheck {
        guard let mountLine = TextParsers.mountLine(for: managedMount.mountPoint, in: mountOutput) else {
            return DoctorCheck(.fail, "Mount \(managedMount.id) is mounted at \(managedMount.mountPoint)")
        }
        if mountLine.contains("noowners") {
            return DoctorCheck(.fail, "Mount \(managedMount.id) mount is owners-enabled", detail: mountLine)
        }
        return DoctorCheck(.pass, "Mount \(managedMount.id) is mounted at \(managedMount.mountPoint)", detail: mountLine)
    }

    private func apfsCheck(_ managedMount: ManagedMount) -> DoctorCheck {
        let result = try? runner.run("/usr/sbin/diskutil", arguments: ["info", managedMount.mountPoint], environment: [:])
        guard let result, result.succeeded, TextParsers.isAPFS(fromDiskutilInfo: result.stdout) else {
            return DoctorCheck(.fail, "Mount \(managedMount.id) filesystem is APFS", detail: managedMount.mountPoint)
        }
        return DoctorCheck(.pass, "Mount \(managedMount.id) filesystem is APFS")
    }

    private func ownersCheck(_ managedMount: ManagedMount) -> DoctorCheck {
        let result = try? runner.run("/usr/sbin/diskutil", arguments: ["info", managedMount.mountPoint], environment: [:])
        guard let result, result.succeeded else {
            return DoctorCheck(.fail, "Mount \(managedMount.id) owners are enabled", detail: managedMount.mountPoint)
        }
        if TextParsers.ownersEnabled(fromDiskutilInfo: result.stdout) == true {
            return DoctorCheck(.pass, "Mount \(managedMount.id) owners are enabled")
        }
        return DoctorCheck(.fail, "Mount \(managedMount.id) owners are enabled", detail: managedMount.mountPoint)
    }

    private func backendCheck(_ managedMount: ManagedMount, hdiutilOutput: String) -> DoctorCheck {
        if TextParsers.hdiutilInfoContains(imagePath: managedMount.imagePath, mountPoint: managedMount.mountPoint, in: hdiutilOutput) {
            return DoctorCheck(.pass, "Mount \(managedMount.id) uses configured sparsebundle", detail: managedMount.imagePath)
        }
        if managedMount.id == "devices", isPhysicalExternalAPFS(managedMount.mountPoint) {
            return DoctorCheck(
                .fail,
                "Mount devices uses supported CoreSimulator backend",
                detail: "physical external APFS volumes can block CoreSimulator writes; mount \(managedMount.imagePath) at \(managedMount.mountPoint)"
            )
        }
        return DoctorCheck(.fail, "Mount \(managedMount.id) uses configured sparsebundle", detail: managedMount.imagePath)
    }

    private func isPhysicalExternalAPFS(_ mountPoint: String) -> Bool {
        guard let result = try? runner.run("/usr/sbin/diskutil", arguments: ["info", mountPoint], environment: [:]),
              result.succeeded,
              TextParsers.isAPFS(fromDiskutilInfo: result.stdout) else {
            return false
        }

        let diskProtocol = TextParsers.diskProtocol(fromDiskutilInfo: result.stdout) ?? ""
        let deviceLocation = TextParsers.deviceLocation(fromDiskutilInfo: result.stdout) ?? ""

        if diskProtocol.localizedCaseInsensitiveContains("Disk Image") {
            return false
        }

        let physicalExternalProtocols = ["USB", "Thunderbolt", "FireWire"]
        if physicalExternalProtocols.contains(where: { diskProtocol.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        return !diskProtocol.isEmpty && deviceLocation.localizedCaseInsensitiveContains("External")
    }

    private func pathExists(_ path: String, label: String) -> DoctorCheck {
        fileManager.fileExists(atPath: path)
            ? DoctorCheck(.pass, label, detail: path)
            : DoctorCheck(.fail, label, detail: path)
    }

    private func executableExists(_ path: String, label: String) -> DoctorCheck {
        fileManager.isExecutableFile(atPath: path)
            ? DoctorCheck(.pass, label, detail: path)
            : DoctorCheck(.fail, label, detail: path)
    }

    private func rejectSymlink(_ path: String) throws {
        if isSymlink(path) {
            throw CommandError("mountpoint must not be a symlink: \(path)", exitCode: 78)
        }
    }

    private func rejectNestedMounts(under mountPoint: String) throws {
        guard let result = try? runner.run("/sbin/mount", arguments: [], environment: [:]), result.succeeded else {
            return
        }
        let nestedMounts = TextParsers.mountedPaths(under: mountPoint, in: result.stdout)
        guard !nestedMounts.isEmpty else {
            return
        }

        throw CommandError(
            """
            mountpoint contains active nested mounts: \(nestedMounts.joined(separator: ", "))
            Shut down simulators and detach those mounts before mounting \(mountPoint).
            """,
            exitCode: 78
        )
    }

    private func backupRoot(for managedMount: ManagedMount, config: StorageConfig) -> String {
        switch managedMount.scope {
        case .user:
            config.mountUserBackupRoot
        case .system:
            config.mountSystemBackupRoot
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func preflight(scope: LaunchdScope, dryRun: Bool) throws {
        guard !dryRun, scope == .system else {
            return
        }
        guard geteuid() == 0 else {
            throw CommandError("system mount scope requires root. Re-run with sudo or use --scope user.", exitCode: 77)
        }
    }

    private func hdiutilCreateCommand(_ managedMount: ManagedMount) -> [String] {
        [
            "/usr/bin/hdiutil",
            "create",
            "-size",
            managedMount.defaultSize,
            "-type",
            "SPARSEBUNDLE",
            "-fs",
            "APFS",
            "-volname",
            managedMount.volumeName,
            managedMount.imagePath
        ]
    }

    private func runOrThrow(_ command: [String]) throws {
        guard let executable = command.first else {
            throw CommandError("empty command")
        }
        let result = try runner.run(executable, arguments: Array(command.dropFirst()), environment: [:])
        guard result.succeeded else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw CommandError(detail.isEmpty ? "command failed: \(command.joined(separator: " "))" : detail)
        }
    }

    private func validatePlist(_ plist: String, name: String) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcode-offload-\(UUID().uuidString).plist")
        try plist.write(to: url, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: url)
        }
        let result = try runner.run("/usr/bin/plutil", arguments: ["-lint", url.path], environment: [:])
        guard result.succeeded else {
            throw CommandError("\(name) plist validation failed")
        }
    }

    private func isMounted(_ mountPoint: String) -> Bool {
        guard let result = try? runner.run("/sbin/mount", arguments: [], environment: [:]), result.succeeded else {
            return false
        }
        return TextParsers.mountLine(for: mountPoint, in: result.stdout) != nil
    }

    private func isMountedFromConfiguredBackend(_ managedMount: ManagedMount) -> Bool {
        guard let result = try? runner.run("/usr/bin/hdiutil", arguments: ["info"], environment: [:]), result.succeeded else {
            return false
        }
        return TextParsers.hdiutilInfoContains(
            imagePath: managedMount.imagePath,
            mountPoint: managedMount.mountPoint,
            in: result.stdout
        )
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
