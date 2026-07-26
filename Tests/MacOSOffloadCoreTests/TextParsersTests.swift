import Testing
@testable import MacOSOffloadCore

@Test func mountLineFindsExactMountPoint() {
    let output = """
    /dev/disk7s1 on /Users/rudi/Library/Developer/CoreSimulator/Devices (apfs, local, nodev, nosuid, journaled, nobrowse)
    /dev/disk11s1 on /Library/Developer/CoreSimulator/Caches (apfs, local, nodev, nosuid, journaled, nobrowse)
    """

    let line = TextParsers.mountLine(
        for: "/Library/Developer/CoreSimulator/Caches",
        in: output
    )

    #expect(line == "/dev/disk11s1 on /Library/Developer/CoreSimulator/Caches (apfs, local, nodev, nosuid, journaled, nobrowse)")
}

@Test func mountLineHandlesSpacesAndPrefixCollisions() {
    let output = """
    /dev/disk1s1 on /Volumes/My Disk/DevicesBackup (apfs, local)
    /dev/disk2s1 on /Volumes/My Disk/Devices (apfs, local, nobrowse)
    """

    let line = TextParsers.mountLine(
        for: "/Volumes/My Disk/Devices",
        in: output
    )

    #expect(line == "/dev/disk2s1 on /Volumes/My Disk/Devices (apfs, local, nobrowse)")
}

@Test func mountLineMatchesCanonicalTemporaryPaths() {
    let output = """
    /dev/disk13s1 on /private/tmp/macos-offload/home/Library/Developer/CoreSimulator/Devices (apfs, local, nobrowse)
    """

    let line = TextParsers.mountLine(
        for: "/tmp/macos-offload/home/Library/Developer/CoreSimulator/Devices",
        in: output
    )

    #expect(line == "/dev/disk13s1 on /private/tmp/macos-offload/home/Library/Developer/CoreSimulator/Devices (apfs, local, nobrowse)")
}

@Test func diskutilParsersTrimValues() {
    let output = """
       Volume Name:              XcodeSimulatorDevicesAPFS
       Mount Point:              /Volumes/ExternalXcode
       File System Personality:  APFS
       Owners:                   Enabled
    """

    #expect(TextParsers.volumeName(fromDiskutilInfo: output) == "XcodeSimulatorDevicesAPFS")
    #expect(TextParsers.volumeMountPoint(fromDiskutilInfo: output) == "/Volumes/ExternalXcode")
    #expect(TextParsers.fileSystemPersonality(fromDiskutilInfo: output) == "APFS")
    #expect(TextParsers.isAPFS(fromDiskutilInfo: output))
    #expect(TextParsers.ownersEnabled(fromDiskutilInfo: output) == true)
}

@Test func diskutilParserReportsMissingValues() {
    let output = "   Device Identifier:        disk7s1\n"

    #expect(TextParsers.volumeName(fromDiskutilInfo: output) == nil)
    #expect(TextParsers.volumeMountPoint(fromDiskutilInfo: output) == nil)
    #expect(TextParsers.fileSystemPersonality(fromDiskutilInfo: output) == nil)
    #expect(!TextParsers.isAPFS(fromDiskutilInfo: output))
    #expect(TextParsers.ownersEnabled(fromDiskutilInfo: output) == nil)
}

@Test func diskutilOwnersParserDetectsDisabledOwners() {
    let output = "   Owners:                    Disabled\n"

    #expect(TextParsers.ownersEnabled(fromDiskutilInfo: output) == false)
}

@Test func hdiutilInfoRequiresImageAndMountPointInSameBlock() {
    let output = """
    image-path      : /Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle
    /dev/disk7s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Users/rudi/Library/Developer/CoreSimulator/Devices
    ================================================
    image-path      : /Volumes/ExternalXcode/Xcode/XcodeDefaults/DerivedData.sparsebundle
    /dev/disk8s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Users/rudi/Library/Developer/Xcode/DerivedData
    """

    #expect(TextParsers.hdiutilInfoContains(
        imagePath: "/Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle",
        mountPoint: "/Users/rudi/Library/Developer/CoreSimulator/Devices",
        in: output
    ))
    #expect(!TextParsers.hdiutilInfoContains(
        imagePath: "/Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle",
        mountPoint: "/Users/rudi/Library/Developer/Xcode/DerivedData",
        in: output
    ))
}

@Test func hdiutilAttachedDevicesReturnsDevicesForUnmountedImageBlocks() {
    let output = """
    image-path      : /Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle
    /dev/disk12\tGUID_partition_scheme
    /dev/disk12s1\tEFI
    /dev/disk13\tEF57347C-0000-11AA-AA11-00306543ECAC
    /dev/disk13s1\t41504653-0000-11AA-AA11-00306543ECAC
    ================================================
    image-path      : /Volumes/ExternalXcode/Xcode/XcodeDefaults/DerivedData.sparsebundle
    /dev/disk14\tGUID_partition_scheme
    /dev/disk15s1\t41504653-0000-11AA-AA11-00306543ECAC\t/Users/rudi/Library/Developer/Xcode/DerivedData
    """

    #expect(TextParsers.hdiutilAttachedDevices(
        imagePath: "/Volumes/ExternalXcode/Xcode/CoreSimulator/DeviceSet.sparsebundle",
        in: output
    ) == ["/dev/disk12"])
}

@Test func launchctlLastExitParserFindsStatus() {
    let output = """
    domain = system
    service = io.github.rudironsoni.macos-offload.caches
    last exit code = 0
    """

    #expect(TextParsers.launchctlLastExitStatus(from: output) == 0)
}

@Test func launchctlLastExitParserFindsNonZeroStatus() {
    let output = """
    path = /Library/LaunchDaemons/io.github.rudironsoni.macos-offload.caches.plist
    last exit status = -78
    """

    #expect(TextParsers.launchctlLastExitStatus(from: output) == -78)
}

@Test func connectionFailureParserMatchesCoreSimulatorErrors() {
    #expect(TextParsers.containsConnectionFailure("The connection was interrupted. Code=409"))
    #expect(TextParsers.containsConnectionFailure("Failed to connect to CoreSimulatorService"))
    #expect(!TextParsers.containsConnectionFailure("invalid device type"))
}

@Test func shellQuoteOnlyQuotesWhenNeeded() {
    #expect("/Volumes/ExternalXcode/Xcode".shellQuoted == "/Volumes/ExternalXcode/Xcode")
    #expect("/Volumes/My Disk/Xcode".shellQuoted == "'/Volumes/My Disk/Xcode'")
    #expect("Rudi's Disk".shellQuoted == "'Rudi'\\''s Disk'")
    #expect("".shellQuoted == "''")
}
