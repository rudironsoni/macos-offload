import Foundation

public enum ActionLogFormatter {
    public static func messages(for actions: [String]) -> [String] {
        var seen = Set<String>()
        var messages: [String] = []

        for action in actions {
            guard let message = message(for: action), !seen.contains(message) else {
                continue
            }
            seen.insert(message)
            messages.append(message)
        }

        return messages
    }

    private static func message(for action: String) -> String? {
        if let path = suffix(after: "already mounted ", in: action) {
            return "\(displayName(for: path)) is already mounted"
        }
        if let path = suffix(after: "already prepared ", in: action) {
            return "\(displayName(for: path)) is already prepared"
        }
        if let path = suffix(after: "not mounted ", in: action) {
            return "\(displayName(for: path)) is already unmounted"
        }
        if action.hasPrefix("/usr/bin/hdiutil detach /dev/disk") {
            return "Detach stale sparsebundle attachment"
        }
        if action.hasPrefix("/usr/bin/hdiutil detach "), action.contains("macos-offload-images-") {
            return nil
        }
        if action.hasPrefix("/usr/bin/hdiutil detach ") {
            let path = suffix(after: "/usr/bin/hdiutil detach ", in: action) ?? ""
            return "Unmount \(displayName(for: path))"
        }
        if action.hasPrefix("/usr/bin/hdiutil create ") {
            return "Create \(displayName(for: action)) sparsebundle"
        }
        if action.hasPrefix("/usr/bin/hdiutil attach ") {
            return attachMessage(for: action)
        }
        if action.hasPrefix("mv ") {
            let source = action.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            return "Back up existing \(displayName(for: source))"
        }
        if action.hasPrefix("write ") {
            return writeMessage(for: action)
        }
        if action.hasPrefix("rm -f ") {
            return removeMessage(for: action)
        }
        if action.hasPrefix("launchctl bootout ") {
            return "Unload existing \(launchdName(for: action))"
        }
        if action.hasPrefix("launchctl bootstrap ") {
            return "Load \(launchdName(for: action))"
        }
        if action.contains("simctl runtime scan-and-mount") {
            return "Refresh simulator runtime mounts"
        }
        if action.contains("launchctl setenv XCODES_DIRECTORY") {
            return "Set XCODES_DIRECTORY for launchd sessions"
        }
        if action.hasPrefix("mkdir -p ") || action.hasPrefix("chown ") || action.hasPrefix("chmod ") {
            return nil
        }
        return action
    }

    private static func attachMessage(for action: String) -> String {
        let mountPoint = value(after: " -mountpoint ", in: action)
        if action.contains("macos-offload-images-") && action.contains("Images.sparsebundle") {
            return "Prepare CoreSimulator Images sparsebundle"
        }
        if let mountPoint {
            return "Mount \(displayName(for: mountPoint))"
        }
        return "Attach sparsebundle"
    }

    private static func writeMessage(for action: String) -> String {
        let path = suffix(after: "write ", in: action) ?? action
        if path.contains("PrivilegedHelperTools") {
            return "Install system mount helper"
        }
        if path.contains("LaunchDaemons") {
            return "Install system LaunchDaemon"
        }
        if path.contains("LaunchAgents") {
            return "Install user LaunchAgent"
        }
        if path.hasSuffix(".manifest") {
            return "Record backup manifest"
        }
        return "Write \(displayName(for: path))"
    }

    private static func removeMessage(for action: String) -> String {
        let path = suffix(after: "rm -f ", in: action) ?? action
        if path.contains("LaunchDaemons") {
            return "Remove system LaunchDaemon"
        }
        if path.contains("LaunchAgents") {
            return "Remove user LaunchAgent"
        }
        if path.contains("PrivilegedHelperTools") {
            return "Remove system mount helper"
        }
        return "Remove \(displayName(for: path))"
    }

    private static func displayName(for path: String) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if normalized.contains("CoreSimulator/Devices") || normalized.contains("DeviceSet.sparsebundle") {
            return "CoreSimulator Devices"
        }
        if normalized.contains("Xcode/DerivedData") || normalized.contains("DerivedData.sparsebundle") {
            return "Xcode DerivedData"
        }
        if normalized.contains("Xcode/Archives") || normalized.contains("Archives.sparsebundle") {
            return "Xcode Archives"
        }
        if normalized.contains("CoreSimulator/Caches") || normalized.contains("Caches.sparsebundle") {
            return "CoreSimulator Caches"
        }
        if normalized.contains("CoreSimulator/Images") || normalized.contains("Images.sparsebundle") {
            return "CoreSimulator Images"
        }
        if normalized.contains("CoreSimulator/Volumes") || normalized.contains("Volumes.sparsebundle") {
            return "CoreSimulator Volumes"
        }
        if normalized.contains("/Applications/Xcodes") || normalized.contains("XcodeApps.sparsebundle") {
            return "Xcode applications"
        }
        if normalized.contains(".local/bin/xcrun") {
            return "xcrun shim"
        }
        if normalized.contains(".local/bin/simctl") {
            return "simctl shim"
        }
        if normalized.contains(".local/bin/xcodebuild") {
            return "xcodebuild shim"
        }
        return normalized
    }

    private static func launchdName(for action: String) -> String {
        if action.contains("mounts-system") {
            return "system LaunchDaemon"
        }
        if action.contains("mounts-user") {
            return "user LaunchAgent"
        }
        if action.contains("caches.plist") {
            return "system LaunchDaemon"
        }
        if action.contains("device-store.plist") {
            return "user LaunchAgent"
        }
        return "launchd job"
    }

    private static func value(after marker: String, in action: String) -> String? {
        guard let range = action.range(of: marker) else {
            return nil
        }

        let rest = String(action[range.upperBound...])
        if rest.hasPrefix("'") {
            let body = rest.dropFirst()
            if let end = body.firstIndex(of: "'") {
                return String(body[..<end])
            }
        }
        return rest.split(separator: " ").first.map(String.init)
    }

    private static func suffix(after marker: String, in action: String) -> String? {
        guard let range = action.range(of: marker) else {
            return nil
        }
        return String(action[range.upperBound...])
    }
}
