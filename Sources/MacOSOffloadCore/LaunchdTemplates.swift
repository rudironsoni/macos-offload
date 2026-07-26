import Foundation

@available(*, deprecated, message: "Use MountLaunchdTemplates. The root cache LaunchDaemon is retired.")
public struct LaunchdTemplates {
    public let config: StorageConfig
    public let toolPath: String

    public init(config: StorageConfig, toolPath: String) {
        self.config = config
        self.toolPath = toolPath
    }

    public var userAgentPlist: String {
        MountLaunchdTemplates(config: config, toolPath: toolPath).userAgentPlist
    }

    public var systemDaemonPlist: String {
        MountLaunchdTemplates(config: config, toolPath: toolPath).systemDaemonPlist
    }

    public var cacheMountHelper: String {
        MountLaunchdTemplates(config: config, toolPath: toolPath).systemHelper
    }
}
