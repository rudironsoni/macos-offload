import Foundation

public enum MountStatusFormatter {
    public static func messages(for report: MountStatusReport) -> [String] {
        if let lifecycle = report.lifecycle, lifecycle.state != .ready {
            let detail = lifecycle.lastError.map { ": \($0)" } ?? ""
            return ["FAIL mount lifecycle \(lifecycle.state.rawValue)\(detail)"]
        }
        let problemChecks = report.checks.filter { $0.status != .pass }
        if !problemChecks.isEmpty {
            return problemChecks.map(\.humanLine)
        }

        var messages: [String] = []
        var seen = Set<String>()
        for check in report.checks {
            guard let message = message(for: check), !seen.contains(message) else {
                continue
            }
            seen.insert(message)
            messages.append(message)
        }

        if messages.isEmpty, report.passed {
            return ["OK all configured mount checks passed"]
        }
        return messages
    }

    private static func message(for check: DoctorCheck) -> String? {
        if check.label.hasPrefix("Mount "), check.label.contains(" is mounted at") {
            let id = mountID(in: check.label)
            return "OK \(displayName(for: id)) is mounted"
        }
        if check.label == "Mount user LaunchAgent exists" {
            return "OK user LaunchAgent is installed"
        }
        if check.label == "Mount system LaunchDaemon exists" {
            return "OK system LaunchDaemon is installed"
        }
        if check.label == "Mount system helper exists" {
            return "OK system mount helper is installed"
        }
        return nil
    }

    private static func mountID(in label: String) -> String {
        let prefix = "Mount "
        guard label.hasPrefix(prefix) else {
            return label
        }
        let withoutPrefix = String(label.dropFirst(prefix.count))
        return withoutPrefix.components(separatedBy: " ").first ?? withoutPrefix
    }

    private static func displayName(for id: String) -> String {
        switch id {
        case "devices":
            return "CoreSimulator Devices"
        case "derived-data":
            return "Xcode DerivedData"
        case "archives":
            return "Xcode Archives"
        case "caches":
            return "CoreSimulator Caches"
        case "images":
            return "CoreSimulator Images"
        case "volumes":
            return "CoreSimulator Volumes"
        case "xcode-apps":
            return "Xcode applications"
        default:
            return id
        }
    }
}
