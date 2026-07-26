import Foundation

public struct ShimTemplate: Equatable, Sendable {
    public let name: String
    public let body: String
}

public enum ShimTemplates {
    public static func renderAll(config: StorageConfig, toolPath: String) -> [ShimTemplate] {
        [
            ShimTemplate(name: "xcrun", body: xcrun(toolPath: toolPath, config: config)),
            ShimTemplate(name: "simctl", body: simctl(toolPath: toolPath, config: config)),
            ShimTemplate(name: "xcodebuild", body: xcodebuild(toolPath: toolPath, config: config))
        ]
    }

    public static func xcrun(toolPath: String, config: StorageConfig) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        if [ "${1:-}" = "simctl" ]; then
          shift
          exec \(toolPath.shellQuoted) wrap-simctl --root \(config.root.shellQuoted) --home \(config.home.shellQuoted) "$@"
        fi

        exec \(toolPath.shellQuoted) wrap-xcrun --root \(config.root.shellQuoted) --home \(config.home.shellQuoted) "$@"
        """
    }

    public static func simctl(toolPath: String, config: StorageConfig) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        exec \(toolPath.shellQuoted) wrap-simctl --root \(config.root.shellQuoted) --home \(config.home.shellQuoted) "$@"
        """
    }

    public static func xcodebuild(toolPath: String, config: StorageConfig) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        exec \(toolPath.shellQuoted) wrap-xcodebuild --root \(config.root.shellQuoted) --home \(config.home.shellQuoted) "$@"
        """
    }
}
