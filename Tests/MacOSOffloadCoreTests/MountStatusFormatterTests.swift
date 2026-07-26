import Testing
@testable import MacOSOffloadCore

@Test func mountStatusFormatterSummarizesHealthyMounts() {
    let report = MountStatusReport(checks: [
        DoctorCheck(.pass, "Mount caches mountpoint is not a symlink", detail: "/Library/Developer/CoreSimulator/Caches"),
        DoctorCheck(.pass, "Mount caches is mounted at /Library/Developer/CoreSimulator/Caches", detail: "/dev/disk1s1 on /Library/Developer/CoreSimulator/Caches"),
        DoctorCheck(.pass, "Mount caches filesystem is APFS"),
        DoctorCheck(.pass, "Mount images is mounted at /Library/Developer/CoreSimulator/Images", detail: "/dev/disk2s1 on /Library/Developer/CoreSimulator/Images"),
        DoctorCheck(.pass, "Mount volumes is mounted at /Library/Developer/CoreSimulator/Volumes", detail: "/dev/disk3s1 on /Library/Developer/CoreSimulator/Volumes"),
        DoctorCheck(.pass, "Mount xcode-apps is mounted at /Applications/Xcodes", detail: "/dev/disk4s1 on /Applications/Xcodes"),
        DoctorCheck(.pass, "Mount system LaunchDaemon exists", detail: "/Library/LaunchDaemons/io.github.rudironsoni.macos-offload.mounts-system.plist"),
        DoctorCheck(.pass, "Mount system helper exists", detail: "/Library/PrivilegedHelperTools/io.github.rudironsoni.macos-offload.mounts-system")
    ])

    #expect(MountStatusFormatter.messages(for: report) == [
        "OK CoreSimulator Caches is mounted",
        "OK CoreSimulator Images is mounted",
        "OK CoreSimulator Volumes is mounted",
        "OK Xcode applications is mounted",
        "OK system LaunchDaemon is installed",
        "OK system mount helper is installed"
    ])
}

@Test func mountStatusFormatterShowsOnlyProblemsWhenUnhealthy() {
    let report = MountStatusReport(checks: [
        DoctorCheck(.pass, "Mount caches mountpoint is not a symlink", detail: "/Library/Developer/CoreSimulator/Caches"),
        DoctorCheck(.fail, "Mount caches is not mounted at /Library/Developer/CoreSimulator/Caches"),
        DoctorCheck(.warn, "Mount system LaunchDaemon last exit status is non-zero", detail: "78")
    ])

    #expect(MountStatusFormatter.messages(for: report) == [
        "FAIL Mount caches is not mounted at /Library/Developer/CoreSimulator/Caches",
        "WARN Mount system LaunchDaemon last exit status is non-zero: 78"
    ])
}
