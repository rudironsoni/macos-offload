import Foundation

public struct MountLaunchdTemplates {
    public let config: StorageConfig
    public let toolPath: String

    public init(config: StorageConfig, toolPath: String) {
        self.config = config
        self.toolPath = toolPath
    }

    public var userAgentPlist: String {
        plist(
            label: config.mountUserLaunchAgentLabel,
            programArguments: [
                toolPath,
                "mounts",
                "agent",
                "--root",
                config.root,
                "--home",
                config.home
            ],
            runAtLoad: true,
            keepAlive: true,
            stdout: "\(config.home)/Library/Logs/xcode-offload-mounts-user.log",
            stderr: "\(config.home)/Library/Logs/xcode-offload-mounts-user.err"
        )
    }

    @available(*, deprecated, message: "System-owned CoreSimulator mounts are retired.")
    public var systemDaemonPlist: String {
        plist(
            label: config.mountSystemLaunchDaemonLabel,
            programArguments: [config.mountSystemHelperPath],
            runAtLoad: false,
            keepAlive: false,
            stdout: "/var/log/xcode-offload-mounts-system.log",
            stderr: "/var/log/xcode-offload-mounts-system.err"
        )
    }

    @available(*, deprecated, message: "System-owned CoreSimulator mounts are retired.")
    public var systemHelper: String {
        """
        #!/bin/zsh
        echo "xcode-offload system mounts are retired; keep CoreSimulator system paths on the internal volume" >&2
        exit 78
        """
    }

    private func plist(
        label: String,
        programArguments: [String],
        runAtLoad: Bool,
        keepAlive: Bool,
        stdout: String,
        stderr: String
    ) -> String {
        let arguments = programArguments
            .map { "        <string>\($0.xmlEscaped)</string>" }
            .joined(separator: "\n")
        let keepAliveValue = keepAlive
            ? """
                <key>KeepAlive</key>
                <true/>
            """
            : ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label.xmlEscaped)</string>
            <key>ProgramArguments</key>
            <array>
        \(arguments)
            </array>
            <key>RunAtLoad</key>
            \(runAtLoad ? "<true/>" : "<false/>")
        \(keepAliveValue)
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(stdout.xmlEscaped)</string>
            <key>StandardErrorPath</key>
            <string>\(stderr.xmlEscaped)</string>
        </dict>
        </plist>
        """
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
