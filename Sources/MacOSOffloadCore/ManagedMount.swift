import Foundation

public enum LaunchdScope: String, Sendable {
    case user
    case system
    case all
}

public enum MountScope: String, Codable, Sendable {
    case user
    case system
}

public enum MountPreparation: String, Codable, Sendable {
    case standard
    case coreSimulatorImages
}

public struct ManagedMount: Codable, Equatable, Sendable {
    public let id: String
    public let scope: MountScope
    public let imagePath: String
    public let mountPoint: String
    public let volumeName: String
    public let defaultSize: String
    public let requiredOwner: String
    public let requiredMode: String
    public let preparation: MountPreparation

    public init(
        id: String,
        scope: MountScope,
        imagePath: String,
        mountPoint: String,
        volumeName: String,
        defaultSize: String,
        requiredOwner: String,
        requiredMode: String,
        preparation: MountPreparation = .standard
    ) {
        self.id = id
        self.scope = scope
        self.imagePath = imagePath
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.defaultSize = defaultSize
        self.requiredOwner = requiredOwner
        self.requiredMode = requiredMode
        self.preparation = preparation
    }
}

public enum ManagedMounts {
    public static func all(config: StorageConfig) -> [ManagedMount] {
        user(config: config)
    }

    public static func matching(scope: LaunchdScope, config: StorageConfig) -> [ManagedMount] {
        switch scope {
        case .user:
            return user(config: config)
        case .system:
            return []
        case .all:
            return all(config: config)
        }
    }

    public static func user(config: StorageConfig) -> [ManagedMount] {
        [
            ManagedMount(
                id: "devices",
                scope: .user,
                imagePath: config.deviceStoreImage,
                mountPoint: config.deviceMount,
                volumeName: "XcodeSimulatorDevices",
                defaultSize: "900g",
                requiredOwner: "user",
                requiredMode: "0755"
            ),
            ManagedMount(
                id: "derived-data",
                scope: .user,
                imagePath: config.mountDerivedDataImage,
                mountPoint: config.mountDerivedDataMount,
                volumeName: "XcodeDerivedData",
                defaultSize: "300g",
                requiredOwner: "user",
                requiredMode: "0755"
            ),
            ManagedMount(
                id: "archives",
                scope: .user,
                imagePath: config.mountArchivesImage,
                mountPoint: config.mountArchivesMount,
                volumeName: "XcodeArchives",
                defaultSize: "200g",
                requiredOwner: "user",
                requiredMode: "0755"
            )
        ]
    }

    @available(*, deprecated, message: "System-owned CoreSimulator mounts are retired. Use legacySystem(config:) only for cleanup.")
    public static func system(config: StorageConfig) -> [ManagedMount] {
        legacySystem(config: config)
    }

    public static func legacySystem(config: StorageConfig) -> [ManagedMount] {
        [
            ManagedMount(
                id: "caches",
                scope: .system,
                imagePath: config.cacheImage,
                mountPoint: config.cacheMount,
                volumeName: "XcodeSimulatorCaches",
                defaultSize: "100g",
                requiredOwner: "root:wheel",
                requiredMode: "0755"
            ),
            ManagedMount(
                id: "images",
                scope: .system,
                imagePath: config.mountImagesImage,
                mountPoint: config.mountImagesMount,
                volumeName: "XcodeSimulatorImages",
                defaultSize: "150g",
                requiredOwner: "root:wheel",
                requiredMode: "0755",
                preparation: .coreSimulatorImages
            ),
            ManagedMount(
                id: "volumes",
                scope: .system,
                imagePath: config.mountVolumesImage,
                mountPoint: config.mountVolumesMount,
                volumeName: "XcodeSimulatorVolumes",
                defaultSize: "50g",
                requiredOwner: "root:wheel",
                requiredMode: "0755"
            ),
            ManagedMount(
                id: "xcode-apps",
                scope: .system,
                imagePath: config.mountXcodeAppsImage,
                mountPoint: config.mountXcodeAppsMount,
                volumeName: "XcodeApps",
                defaultSize: "500g",
                requiredOwner: "root:wheel",
                requiredMode: "0755"
            )
        ]
    }
}
