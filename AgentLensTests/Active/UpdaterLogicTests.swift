import Foundation
import XCTest
@testable import OpenBurnBar

// Pure-logic coverage for the in-app updater: channel resolution, phase/offer
// vocabulary, and the installer's testable string helpers (trampoline-script
// generation, hdiutil mount-point parsing, shell quoting). The mount/swap/
// relaunch I/O itself is exercised manually (it terminates the app), but every
// decision around it is verified here.
#if !DISTRIBUTION_MAS
final class UpdaterLogicTests: XCTestCase {

    // MARK: - Channel resolution

    func testSourceBuildResolvesToSource() {
        let channel = UpdateChannelResolver.resolve(
            buildChannelStamp: "source",
            sourceRootHasGit: true,
            isInstalledInApplications: false,
            hasCaskroomReceipt: false
        )
        XCTAssertEqual(channel, .source)
    }

    func testSourceStampWithoutGitIsNotSource() {
        // A release stamped "source" but with no .git (e.g. extracted) must not
        // masquerade as a source build.
        let channel = UpdateChannelResolver.resolve(
            buildChannelStamp: "source",
            sourceRootHasGit: false,
            isInstalledInApplications: true,
            hasCaskroomReceipt: false
        )
        XCTAssertEqual(channel, .dmg)
    }

    func testInstalledWithoutCaskroomResolvesToDMG() {
        let channel = UpdateChannelResolver.resolve(
            buildChannelStamp: "release",
            sourceRootHasGit: false,
            isInstalledInApplications: true,
            hasCaskroomReceipt: false
        )
        XCTAssertEqual(channel, .dmg)
    }

    func testInstalledWithCaskroomResolvesToHomebrew() {
        let channel = UpdateChannelResolver.resolve(
            buildChannelStamp: "release",
            sourceRootHasGit: false,
            isInstalledInApplications: true,
            hasCaskroomReceipt: true
        )
        XCTAssertEqual(channel, .homebrew)
    }

    func testLooseBuildResolvesToUnknown() {
        let channel = UpdateChannelResolver.resolve(
            buildChannelStamp: nil,
            sourceRootHasGit: false,
            isInstalledInApplications: false,
            hasCaskroomReceipt: false
        )
        XCTAssertEqual(channel, .unknown)
    }

    // MARK: - Phase / offer

    func testActionablePhases() {
        XCTAssertFalse(UpdatePhase.idle.isActionable)
        XCTAssertFalse(UpdatePhase.checking.isActionable)
        XCTAssertFalse(UpdatePhase.upToDate.isActionable)
        XCTAssertTrue(UpdatePhase.downloading(progress: 0.5).isActionable)
        XCTAssertTrue(UpdatePhase.verifying.isActionable)
        XCTAssertTrue(UpdatePhase.failed(message: "x").isActionable)
    }

    func testOfferAccessorAndPillText() {
        let dmg = UpdateOffer.directDMG(Self.sampleRelease(version: "1.4.0"))
        XCTAssertEqual(dmg.pillText, "1.4.0")
        XCTAssertEqual(UpdatePhase.available(dmg).offer, dmg)

        XCTAssertEqual(UpdateOffer.homebrew(version: "2.0.0").pillText, "2.0.0")

        let oneCommit = SourceUpdateStatus(behindBy: 1, defaultBranch: "main", currentSHA: "abc", compareURL: nil)
        XCTAssertEqual(UpdateOffer.source(oneCommit).pillText, "1 commit")
        let many = SourceUpdateStatus(behindBy: 7, defaultBranch: "main", currentSHA: "abc", compareURL: nil)
        XCTAssertEqual(UpdateOffer.source(many).pillText, "7 commits")

        XCTAssertNil(UpdatePhase.idle.offer)
    }

    // MARK: - Shell quoting

    func testShellSingleQuotedPlainPath() {
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.shellSingleQuoted("/Applications/OpenBurnBar.app"),
            "'/Applications/OpenBurnBar.app'"
        )
    }

    func testShellSingleQuotedWithSpace() {
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.shellSingleQuoted("/Volumes/OpenBurnBar 1.0.2"),
            "'/Volumes/OpenBurnBar 1.0.2'"
        )
    }

    func testShellSingleQuotedEscapesSingleQuote() {
        // a'b  ->  'a'\''b'
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.shellSingleQuoted("a'b"),
            "'a'\\''b'"
        )
    }

    // MARK: - Mount-point parsing

    func testParseMountPointExtractsVolume() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>system-entities</key>
          <array>
            <dict>
              <key>content-hint</key><string>GUID_partition_scheme</string>
              <key>dev-entry</key><string>/dev/disk7</string>
            </dict>
            <dict>
              <key>content-hint</key><string>Apple_HFS</string>
              <key>dev-entry</key><string>/dev/disk7s1</string>
              <key>mount-point</key><string>/Volumes/OpenBurnBar 1.0.2</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.parseMountPoint(fromPlist: plist),
            "/Volumes/OpenBurnBar 1.0.2"
        )
    }

    func testParseMountPointReturnsNilWhenAbsent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>system-entities</key>
          <array>
            <dict><key>dev-entry</key><string>/dev/disk7</string></dict>
          </array>
        </dict>
        </plist>
        """
        XCTAssertNil(DirectDownloadUpdateInstaller.parseMountPoint(fromPlist: plist))
    }

    func testParseMountPointReturnsNilForGarbage() {
        XCTAssertNil(DirectDownloadUpdateInstaller.parseMountPoint(fromPlist: "not a plist"))
    }

    // MARK: - Trampoline script

    func testTrampolineScriptContainsSafeSwapSteps() {
        let script = DirectDownloadUpdateInstaller.makeTrampolineScript(
            appPID: 4242,
            sourcePath: "/Volumes/OpenBurnBar 1.0.2/OpenBurnBar.app",
            mountPoint: "/Volumes/OpenBurnBar 1.0.2",
            destinationPath: "/Applications/OpenBurnBar.app"
        )
        // Waits for the app to exit before touching anything.
        XCTAssertTrue(script.contains("APP_PID=4242"))
        XCTAssertTrue(script.contains("kill -0 \"$APP_PID\""))
        // Frees the gateway port by killing the bundled daemon.
        XCTAssertTrue(script.contains("pkill -f \"$DAEMON\""))
        XCTAssertTrue(script.contains("Contents/Helpers/OpenBurnBarDaemon"))
        // Atomic-ish swap with a rollback branch.
        XCTAssertTrue(script.contains("/usr/bin/ditto"))
        XCTAssertTrue(script.contains("rolling back"))
        XCTAssertTrue(script.contains("/usr/bin/hdiutil detach"))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertTrue(script.contains("/usr/bin/pkill -x \"$APP_EXECUTABLE\""))
        XCTAssertTrue(script.contains("LSREGISTER="))
        XCTAssertTrue(script.contains("kMDItemCFBundleIdentifier == '$BUNDLE_ID'"))
        XCTAssertTrue(script.contains("\"$LSREGISTER\" -dump"))
        XCTAssertTrue(script.contains("platform == \"native\""))
        XCTAssertTrue(script.contains("path ~ /\\/OpenBurnBar\\.app$/"))
        XCTAssertTrue(script.contains("-f -R -trusted \"$DEST\""))
        XCTAssertTrue(script.contains("-u \"$CANDIDATE\""))
        // Paths with spaces are single-quoted safely.
        XCTAssertTrue(script.contains("SRC='/Volumes/OpenBurnBar 1.0.2/OpenBurnBar.app'"))
        XCTAssertTrue(script.contains("MOUNT='/Volumes/OpenBurnBar 1.0.2'"))
        XCTAssertTrue(script.contains("DEST='/Applications/OpenBurnBar.app'"))
        // Bounded wait so a vetoed terminate can't hang forever with the DMG mounted.
        XCTAssertTrue(script.contains("WAITED"))
        XCTAssertTrue(script.contains("aborting (terminate vetoed?)"))
    }

    func testSourceUpdateCommandRunsCanonicalInstallScriptFromQuotedCheckout() {
        let sourceRoot = URL(fileURLWithPath: "/Users/alberto/dev path/BurnBar", isDirectory: true)
        XCTAssertEqual(
            SourceUpdateChannel.sourceUpdateCommand(in: sourceRoot),
            "cd '/Users/alberto/dev path/BurnBar' && bash ./scripts/source-update-install.sh"
        )
        XCTAssertEqual(SourceUpdateChannel.manualUpdateCommand, "bash ./scripts/source-update-install.sh")
    }

    /// Behavioral (not string-containment) test of the swap core the trampoline
    /// runs: ditto the new app in, back up the old, rename into place, clean up.
    func testSwapSequenceReplacesAppAndCleansUp() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OBBSwap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let dest = root.appendingPathComponent("OpenBurnBar.app", isDirectory: true)
        let src = root.appendingPathComponent("Source.app", isDirectory: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: src, withIntermediateDirectories: true)
        try "OLD".write(to: dest.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try "NEW".write(to: src.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        // Mirrors the trampoline's ditto -> mv-backup -> mv-stage -> cleanup.
        let script = """
        set -e
        STAGE="$DEST.new"; BACKUP="$DEST.bak"
        /bin/rm -rf "$STAGE" "$BACKUP"
        /usr/bin/ditto "$SRC" "$STAGE"
        if [ -e "$DEST" ]; then /bin/mv "$DEST" "$BACKUP"; fi
        if /bin/mv "$STAGE" "$DEST"; then /bin/rm -rf "$BACKUP"; else /bin/rm -rf "$DEST"; [ -e "$BACKUP" ] && /bin/mv "$BACKUP" "$DEST"; exit 1; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["DEST": dest.path, "SRC": src.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let marker = try String(contentsOf: dest.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "NEW", "the swapped-in app should be the new one")
        XCTAssertFalse(fileManager.fileExists(atPath: dest.path + ".bak"), "backup should be cleaned up")
        XCTAssertFalse(fileManager.fileExists(atPath: dest.path + ".new"), "stage should be cleaned up")
    }

    // MARK: - Writability gate (auto-install vs DMG fallback)

    func testIsWritableForReplacementTrueForFreshTempTarget() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OBBWritable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("OpenBurnBar.app").path
        // Writable parent, target absent → safe to place.
        XCTAssertTrue(DirectDownloadUpdateInstaller.isWritableForReplacement(target))
    }

    func testIsWritableForReplacementFalseForSIPProtectedPath() {
        // /System is SIP-protected and never user-writable, so auto-install must
        // decline and fall back to opening the DMG.
        XCTAssertFalse(DirectDownloadUpdateInstaller.isWritableForReplacement("/System/OpenBurnBar.app"))
    }

    func testCompareOfferedBuildTreatsEqualBuildAsAlreadyInstalled() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OBBBuildCompare-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("OpenBurnBar.app/Contents", isDirectory: true)
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let info: [String: String] = ["CFBundleVersion": "82"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let appPath = root.appendingPathComponent("OpenBurnBar.app").path
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.compareOfferedBuild(at: appPath, currentBuild: 82),
            .orderedSame
        )
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.compareOfferedBuild(at: appPath, currentBuild: 81),
            .orderedDescending
        )
        XCTAssertEqual(
            DirectDownloadUpdateInstaller.compareOfferedBuild(at: appPath, currentBuild: 83),
            .orderedAscending
        )
    }

    // MARK: - Helpers

    private static func sampleRelease(version: String) -> DirectDownloadRelease {
        DirectDownloadRelease(
            version: version,
            build: "100",
            downloadUrl: URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v\(version)/OpenBurnBar.dmg")!,
            appcastUrl: nil,
            length: 1234,
            sha256: String(repeating: "a", count: 64),
            sparkleEdSignature: "c2lnbmF0dXJl",
            critical: false
        )
    }
}
#endif
