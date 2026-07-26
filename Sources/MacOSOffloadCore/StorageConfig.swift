import Foundation

public struct StorageConfig: Codable, Equatable, Sendable {
    public let root: String
    public let home: String
    public let xcodeRoot: String
    public let coreSimulatorRoot: String
    public let deviceStoreImage: String
    public let cacheImage: String
    public let deviceMount: String
    public let cacheMount: String
    public let derivedData: String
    public let packageCache: String
    public let tmp: String
    public let shimDirectory: String
    public let apfsDeviceVolumeName: String
    public let launchAgentLabel: String
    public let launchDaemonLabel: String
    public let cacheHelperPath: String
    public let userLaunchAgentPath: String
    public let systemLaunchDaemonPath: String
    public let mountUserLaunchAgentLabel: String
    public let mountSystemLaunchDaemonLabel: String
    public let mountSystemHelperPath: String
    public let mountUserLaunchAgentPath: String
    public let mountSystemLaunchDaemonPath: String

    public init(
        root: String,
        home: String = NSHomeDirectory(),
        shimDirectory: String? = nil,
        apfsDeviceVolumeName: String = "XcodeSimulatorDevicesAPFS"
    ) {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
        let xcodeRoot = "\(normalizedRoot)/Xcode"

        self.root = normalizedRoot
        self.home = normalizedHome
        self.xcodeRoot = xcodeRoot
        self.coreSimulatorRoot = "\(xcodeRoot)/CoreSimulator"
        self.deviceStoreImage = "\(xcodeRoot)/CoreSimulator/DeviceSet.sparsebundle"
        self.cacheImage = "\(xcodeRoot)/CoreSimulator/Caches.sparsebundle"
        self.deviceMount = "\(normalizedHome)/Library/Developer/CoreSimulator/Devices"
        self.cacheMount = "/Library/Developer/CoreSimulator/Caches"
        self.derivedData = "\(xcodeRoot)/DerivedData"
        self.packageCache = "\(xcodeRoot)/PackageCache"
        self.tmp = "\(xcodeRoot)/tmp"
        self.shimDirectory = shimDirectory ?? "\(normalizedHome)/.local/bin"
        self.apfsDeviceVolumeName = apfsDeviceVolumeName
        self.launchAgentLabel = "io.github.rudironsoni.macos-offload.device-store"
        self.launchDaemonLabel = "io.github.rudironsoni.macos-offload.caches"
        self.cacheHelperPath = "/Library/PrivilegedHelperTools/io.github.rudironsoni.macos-offload.mount-coresimulator-caches"
        self.userLaunchAgentPath = "\(normalizedHome)/Library/LaunchAgents/io.github.rudironsoni.macos-offload.device-store.plist"
        self.systemLaunchDaemonPath = "/Library/LaunchDaemons/io.github.rudironsoni.macos-offload.caches.plist"
        self.mountUserLaunchAgentLabel = "io.github.rudironsoni.macos-offload.mounts-user"
        self.mountSystemLaunchDaemonLabel = "io.github.rudironsoni.macos-offload.mounts-system"
        self.mountSystemHelperPath = "/Library/PrivilegedHelperTools/io.github.rudironsoni.macos-offload.mounts-system"
        self.mountUserLaunchAgentPath = "\(normalizedHome)/Library/LaunchAgents/io.github.rudironsoni.macos-offload.mounts-user.plist"
        self.mountSystemLaunchDaemonPath = "/Library/LaunchDaemons/io.github.rudironsoni.macos-offload.mounts-system.plist"
    }

    public var xcrunShim: String {
        "\(shimDirectory)/xcrun"
    }

    public var simctlShim: String {
        "\(shimDirectory)/simctl"
    }

    public var xcodebuildShim: String {
        "\(shimDirectory)/xcodebuild"
    }

    public var supportDirectories: [String] {
        [
            xcodeRoot,
            coreSimulatorRoot,
            derivedData,
            packageCache,
            "\(xcodeRoot)/Archives",
            "\(xcodeRoot)/Products",
            "\(xcodeRoot)/Exports",
            "\(xcodeRoot)/Index.noindex",
            "\(xcodeRoot)/Logs",
            "\(xcodeRoot)/Results",
            tmp,
            "\(xcodeRoot)/XCFrameworks",
            URL(fileURLWithPath: deviceMount).deletingLastPathComponent().path
        ]
    }

    public var mountBackupRoot: String {
        "\(xcodeRoot)/Backups/mounts"
    }

    public var mountUserBackupRoot: String {
        "\(xcodeRoot)/UserBackups/mounts"
    }

    public var mountSystemBackupRoot: String {
        "\(xcodeRoot)/SystemBackups/mounts"
    }

    public var mountImagesImage: String {
        "\(xcodeRoot)/CoreSimulator/Images.sparsebundle"
    }

    public var mountVolumesImage: String {
        "\(xcodeRoot)/CoreSimulator/Volumes.sparsebundle"
    }

    public var mountDerivedDataImage: String {
        "\(xcodeRoot)/XcodeDefaults/DerivedData.sparsebundle"
    }

    public var mountArchivesImage: String {
        "\(xcodeRoot)/XcodeDefaults/Archives.sparsebundle"
    }

    public var mountXcodeAppsImage: String {
        "\(xcodeRoot)/XcodeApps.sparsebundle"
    }

    public var mountImagesMount: String {
        "/Library/Developer/CoreSimulator/Images"
    }

    public var mountVolumesMount: String {
        "/Library/Developer/CoreSimulator/Volumes"
    }

    public var mountDerivedDataMount: String {
        "\(home)/Library/Developer/Xcode/DerivedData"
    }

    public var mountArchivesMount: String {
        "\(home)/Library/Developer/Xcode/Archives"
    }

    public var mountXcodeAppsMount: String {
        "/Applications/Xcodes"
    }

    public var applicationSupportDirectory: String {
        "\(home)/Library/Application Support/macos-offload"
    }

    public var mountConfigurationPath: String {
        "\(applicationSupportDirectory)/mounts.json"
    }

    public var mountStatePath: String {
        "\(applicationSupportDirectory)/mount-state.json"
    }

    public var mountLockPath: String {
        "\(applicationSupportDirectory)/mounts.lock"
    }

    public var xcodeApplicationsDirectory: String {
        xcodeRoot
    }
}

public enum RootResolver {
    public static func resolveRoot(
        explicitRoot: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: CommandRunning = SystemCommandRunner()
    ) throws -> String {
        if let explicitRoot, !explicitRoot.isEmpty {
            return explicitRoot
        }

        if let root = environment["MACOS_OFFLOAD_ROOT"], !root.isEmpty {
            return root
        }

        let volumeUUID = environment["MACOS_OFFLOAD_VOLUME_UUID"]
        let volumeName = environment["MACOS_OFFLOAD_VOLUME_NAME"]

        if let volumeUUID,
           !volumeUUID.isEmpty,
           let result = try? runner.run("/usr/sbin/diskutil", arguments: ["info", volumeUUID], environment: [:]),
           result.succeeded,
           let mountPoint = TextParsers.volumeMountPoint(fromDiskutilInfo: result.stdout),
           !mountPoint.isEmpty {
            return mountPoint
        }

        if let volumeName, !volumeName.isEmpty {
            return "/Volumes/\(volumeName)"
        }

        throw CommandError("missing storage root. Pass --root PATH or set MACOS_OFFLOAD_ROOT.", exitCode: 78)
    }
}
