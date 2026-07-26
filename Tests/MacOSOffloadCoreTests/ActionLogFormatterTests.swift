import Testing
@testable import MacOSOffloadCore

@Test func actionLogFormatterSummarizesMountRepairCommands() {
    let actions = [
        "mkdir -p /Volumes/External/Xcode/CoreSimulator",
        "mkdir -p /Volumes/External/Xcode/CoreSimulator",
        "/usr/bin/hdiutil detach /dev/disk10",
        "mkdir -p /var/folders/T/macos-offload-images-1234",
        "/usr/bin/hdiutil attach /Volumes/External/Xcode/CoreSimulator/Images.sparsebundle -mountpoint /var/folders/T/macos-offload-images-1234 -nobrowse -owners on",
        "mkdir -p /var/folders/T/macos-offload-images-1234/mnt",
        "chmod 1777 /var/folders/T/macos-offload-images-1234/mnt",
        "/usr/bin/hdiutil detach /var/folders/T/macos-offload-images-1234",
        "/usr/bin/hdiutil attach /Volumes/External/Xcode/CoreSimulator/Caches.sparsebundle -mountpoint /Library/Developer/CoreSimulator/Caches -nobrowse -owners on",
        "write /Volumes/External/Xcode/SystemBackups/mounts/20260704-154745/images.manifest",
        "mv /Library/Developer/CoreSimulator/Images /Volumes/External/Xcode/SystemBackups/mounts/20260704-154745/images",
        "/usr/bin/hdiutil attach /Volumes/External/Xcode/CoreSimulator/Images.sparsebundle -mountpoint /Library/Developer/CoreSimulator/Images -nobrowse -owners on",
        "/usr/bin/hdiutil attach /Volumes/External/Xcode/CoreSimulator/Volumes.sparsebundle -mountpoint /Library/Developer/CoreSimulator/Volumes -nobrowse -owners on",
        "/usr/bin/hdiutil attach /Volumes/External/Xcode/XcodeApps.sparsebundle -mountpoint /Applications/Xcodes -nobrowse -owners on",
        "/usr/bin/xcrun simctl runtime scan-and-mount",
        "write /Library/PrivilegedHelperTools/io.github.rudironsoni.macos-offload.mounts-system",
        "write /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.mounts-system.plist",
        "launchctl bootout system /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.mounts-system.plist || true",
        "launchctl bootstrap system /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.mounts-system.plist"
    ]

    #expect(ActionLogFormatter.messages(for: actions) == [
        "Detach stale sparsebundle attachment",
        "Prepare CoreSimulator Images sparsebundle",
        "Mount CoreSimulator Caches",
        "Record backup manifest",
        "Back up existing CoreSimulator Images",
        "Mount CoreSimulator Images",
        "Mount CoreSimulator Volumes",
        "Mount Xcode applications",
        "Refresh simulator runtime mounts",
        "Install system mount helper",
        "Install system LaunchDaemon",
        "Unload existing system LaunchDaemon",
        "Load system LaunchDaemon"
    ])
}

@Test func actionLogFormatterDeduplicatesAndKeepsUnknownActions() {
    let actions = [
        "already mounted /Library/Developer/CoreSimulator/Caches",
        "already mounted /Library/Developer/CoreSimulator/Caches",
        "custom maintenance step"
    ]

    #expect(ActionLogFormatter.messages(for: actions) == [
        "CoreSimulator Caches is already mounted",
        "custom maintenance step"
    ])
}

@Test func actionLogFormatterNamesLegacyLaunchdJobs() {
    let actions = [
        "launchctl bootout system /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.caches.plist || true",
        "launchctl bootstrap system /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.caches.plist",
        "launchctl bootout gui/501 /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.device-store.plist || true",
        "launchctl bootstrap gui/501 /Users/rudi/Library/LaunchAgents/io.github.rudironsoni.macos-offload.device-store.plist"
    ]

    #expect(ActionLogFormatter.messages(for: actions) == [
        "Unload existing system LaunchDaemon",
        "Load system LaunchDaemon",
        "Unload existing user LaunchAgent",
        "Load user LaunchAgent"
    ])
}
