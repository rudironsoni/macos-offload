import Foundation

public struct VersionInfo: Codable, Equatable, Sendable {
    public let version: String
    public let commit: String
    public let buildDate: String
    public let dirty: Bool

    public init(version: String, commit: String, buildDate: String, dirty: Bool) {
        self.version = version
        self.commit = commit
        self.buildDate = buildDate
        self.dirty = dirty
    }

    public var displayString: String {
        if commit.isEmpty && buildDate.isEmpty {
            return version
        }

        var fields = ["macos-offload \(version)"]
        if !commit.isEmpty {
            fields.append("commit \(commit)")
        }
        if !buildDate.isEmpty {
            fields.append("built \(buildDate)")
        }
        if dirty {
            fields.append("dirty")
        }
        return fields.joined(separator: ", ")
    }
}

public enum Version {
    public static var current: VersionInfo {
        VersionInfo(
            version: GeneratedBuildMetadata.version,
            commit: GeneratedBuildMetadata.commit,
            buildDate: GeneratedBuildMetadata.buildDate,
            dirty: GeneratedBuildMetadata.dirty
        )
    }
}
