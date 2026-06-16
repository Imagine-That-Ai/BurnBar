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
        // Paths with spaces are single-quoted safely.
        XCTAssertTrue(script.contains("SRC='/Volumes/OpenBurnBar 1.0.2/OpenBurnBar.app'"))
        XCTAssertTrue(script.contains("MOUNT='/Volumes/OpenBurnBar 1.0.2'"))
        XCTAssertTrue(script.contains("DEST='/Applications/OpenBurnBar.app'"))
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
