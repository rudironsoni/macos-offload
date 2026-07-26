import Darwin
import Foundation

public enum MountLifecycleState: String, Codable, Sendable {
    case waitingForVolume
    case reconciling
    case ready
    case blockedWrongVolume
    case blockedWrongBackend
    case failed
}

public struct MountConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let rootPath: String
    public let volumeUUID: String

    public init(schemaVersion: Int = 1, rootPath: String, volumeUUID: String) {
        self.schemaVersion = schemaVersion
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
    }
}

public struct MountLifecycleSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: MountLifecycleState
    public let rootPath: String
    public let volumeUUID: String?
    public let mountedIDs: [String]
    public let lastTransitionAt: Date
    public let lastError: String?

    public init(
        schemaVersion: Int = 1,
        state: MountLifecycleState,
        rootPath: String,
        volumeUUID: String?,
        mountedIDs: [String],
        lastTransitionAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.mountedIDs = mountedIDs
        self.lastTransitionAt = lastTransitionAt
        self.lastError = lastError
    }
}

enum MountLifecycleFiles {
    static func loadConfiguration(
        config: StorageConfig,
        fileManager: FileManager
    ) throws -> MountConfiguration? {
        guard fileManager.fileExists(atPath: config.mountConfigurationPath) else {
            return nil
        }
        return try decoder.decode(
            MountConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: config.mountConfigurationPath))
        )
    }

    static func write(
        configuration: MountConfiguration,
        config: StorageConfig,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            atPath: config.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(
            to: URL(fileURLWithPath: config.mountConfigurationPath),
            options: .atomic
        )
    }

    static func loadSnapshot(
        config: StorageConfig,
        fileManager: FileManager
    ) -> MountLifecycleSnapshot? {
        guard fileManager.fileExists(atPath: config.mountStatePath) else {
            return nil
        }
        return try? decoder.decode(
            MountLifecycleSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: config.mountStatePath))
        )
    }

    static func write(
        snapshot: MountLifecycleSnapshot,
        config: StorageConfig,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            atPath: config.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: config.mountStatePath),
            options: .atomic
        )
    }

    static func withLock<T>(
        config: StorageConfig,
        fileManager: FileManager,
        timeoutSeconds: TimeInterval = 60,
        operation: () throws -> T
    ) throws -> T {
        try fileManager.createDirectory(
            atPath: config.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let descriptor = open(config.mountLockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CommandError("cannot open mount lifecycle lock: \(config.mountLockPath)", exitCode: 74)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                throw CommandError(
                    "timed out waiting for mount lifecycle lock: \(config.mountLockPath)",
                    exitCode: 75
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try operation()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
