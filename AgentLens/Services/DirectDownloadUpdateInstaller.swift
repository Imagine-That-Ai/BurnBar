import AppKit
import Darwin
import Foundation
import os

// Mounts a verified update DMG, validates the app inside, swaps it into
// /Applications, and relaunches — the part the legacy checker left to the user
// (it merely opened the DMG to drag by hand).
//
// Trust note: we only reach here after DirectDownloadArtifactVerifier has
// verified the SHA-256 + Ed25519 signature over the whole DMG against the
// pinned SUPublicEDKey, so the bytes — and the .app inside — are already
// authenticated. The codesign check below is belt-and-suspenders against a
// corrupt extraction, not the trust anchor.
#if !DISTRIBUTION_MAS

enum DirectDownloadUpdateInstallError: LocalizedError, Equatable {
    case applicationsNotWritable
    case mountFailed(String)
    case appNotFoundInDMG
    case codesignRejected(String)
    case spawnFailed(Int32)
    case versionUnreadable
    case downgradeBlocked(current: Int, offered: Int)

    var errorDescription: String? {
        switch self {
        case .applicationsNotWritable:
            return "OpenBurnBar in /Applications is not writable by this user, so it can't be replaced automatically."
        case let .mountFailed(detail):
            return "The update disk image could not be mounted. \(detail)"
        case .appNotFoundInDMG:
            return "The update disk image did not contain OpenBurnBar.app."
        case let .codesignRejected(detail):
            return "The update's code signature did not validate. \(detail)"
        case let .spawnFailed(code):
            return "The updater helper could not be launched (error \(code))."
        case .versionUnreadable:
            return "The update's version could not be read from the disk image."
        case let .downgradeBlocked(current, offered):
            return "Refusing to install build \(offered) over the newer/equal build \(current) already installed."
        }
    }
}

enum DirectDownloadUpdateInstaller {
    private static let bundleIdentifier = "com.openburnbar.app"
    private static let executableName = "OpenBurnBar"
    private static let daemonRelativePath = "Contents/Helpers/OpenBurnBarDaemon"
    private static let launchServicesRegisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

    /// Mounts the verified DMG, validates the bundle, then spawns a detached
    /// trampoline that swaps it over the *running* app bundle and relaunches
    /// after this process exits, then terminates the app. Throws *before* any
    /// destructive step when a precondition fails so the caller can fall back to
    /// opening the DMG; on success this never returns normally (the app
    /// terminates).
    @MainActor
    static func installAndRelaunch(dmgAt dmgURL: URL) async throws {
        // Replace the bundle wherever it actually runs (/Applications OR
        // ~/Applications), not a hardcoded path — otherwise a user-local install
        // would clobber/relaunch the wrong copy.
        let destinationPath = Bundle.main.bundleURL.standardizedFileURL.path
        guard isWritableForReplacement(destinationPath) else {
            throw DirectDownloadUpdateInstallError.applicationsNotWritable
        }
        let appPID = ProcessInfo.processInfo.processIdentifier
        let currentBuild = Self.currentBundleBuild()

        // Mount + locate + validate + anti-downgrade are blocking shell-outs;
        // keep them off the main actor so the UI's progress animation never stalls.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepareInstall(dmgURL: dmgURL, currentBuild: currentBuild)
        }.value

        guard case let .ready(install) = prepared else {
            // Same CFBundleVersion is already on disk. The feed can still look
            // "newer" when marketing strings differ (`1.0.40+repair.36` vs
            // `1.0.40`); do not swap or relaunch.
            return
        }

        do {
            try spawnTrampoline(
                appPID: appPID,
                sourcePath: install.appPath,
                mountPoint: install.mountPoint,
                destinationPath: destinationPath
            )
        } catch {
            detach(install.mountPoint)
            throw error
        }
        // The trampoline is now an independent session; finishing the swap once
        // we exit. Quitting also tears down the bundled daemon.
        NSApp.terminate(nil)
    }

    private static func currentBundleBuild() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    // MARK: - Prepare (off-main, blocking)

    private struct PreparedInstall {
        let mountPoint: String
        let appPath: String
    }

    private enum PreparedOutcome {
        case alreadyInstalled
        case ready(PreparedInstall)
    }

    private nonisolated static func prepareInstall(dmgURL: URL, currentBuild: Int) throws -> PreparedOutcome {
        let mountPoint = try mount(dmgURL)
        do {
            let appPath = try locateApp(in: mountPoint)
            try validateSignature(at: appPath)
            // Anti-downgrade/replay: even a validly-signed but OLD DMG (served by
            // a tampered, unsigned feed claiming a higher version) must not be
            // installed over a newer build. Equal build is already installed.
            guard let comparison = compareOfferedBuild(at: appPath, currentBuild: currentBuild) else {
                throw DirectDownloadUpdateInstallError.versionUnreadable
            }
            switch comparison {
            case .orderedAscending:
                let offered = offeredBundleBuild(at: appPath) ?? 0
                throw DirectDownloadUpdateInstallError.downgradeBlocked(current: currentBuild, offered: offered)
            case .orderedSame:
                detach(mountPoint)
                return .alreadyInstalled
            case .orderedDescending:
                return .ready(PreparedInstall(mountPoint: mountPoint, appPath: appPath))
            }
        } catch {
            detach(mountPoint)
            throw error
        }
    }

    /// Reads the mounted bundle's `CFBundleVersion`. The mounted image is the
    /// authenticated artifact (Ed25519 over the DMG bytes); this closes the
    /// downgrade window the unsigned feed metadata would otherwise leave open.
    nonisolated static func compareOfferedBuild(at appPath: String, currentBuild: Int) -> ComparisonResult? {
        guard let offeredBuild = offeredBundleBuild(at: appPath) else { return nil }
        if offeredBuild < currentBuild { return .orderedAscending }
        if offeredBuild > currentBuild { return .orderedDescending }
        return .orderedSame
    }

    private nonisolated static func offeredBundleBuild(at appPath: String) -> Int? {
        let infoPlistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: infoPlistPath),
              let buildString = info["CFBundleVersion"] as? String else {
            return nil
        }
        return Int(buildString)
    }

    private nonisolated static func mount(_ dmgURL: URL) throws -> String {
        // -readonly so the validated content can't be mutated under us between
        // codesign-verify and the trampoline's ditto copy (TOCTOU).
        let result = runProcess(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-noautoopen", "-readonly", "-plist", dmgURL.path]
        )
        guard result.status == 0 else {
            throw DirectDownloadUpdateInstallError.mountFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        guard let mountPoint = parseMountPoint(fromPlist: result.stdout) else {
            throw DirectDownloadUpdateInstallError.mountFailed("No mount point in hdiutil output.")
        }
        return mountPoint
    }

    /// Parses the `mount-point` of the mounted volume out of `hdiutil attach
    /// -plist` output. Pure + testable.
    nonisolated static func parseMountPoint(fromPlist plistText: String) -> String? {
        guard let data = plistText.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil), // try?-ok(malformed plist means mount failed)
              let dict = root as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            return nil
        }
        // Prefer the entity that actually exposes a mount point (the data volume).
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            .filter { !$0.isEmpty }
        // The deepest/most specific mount point is the volume root.
        return mountPoints.max { $0.count < $1.count }
    }

    private nonisolated static func locateApp(in mountPoint: String) throws -> String {
        let fileManager = FileManager.default
        let direct = (mountPoint as NSString).appendingPathComponent("OpenBurnBar.app")
        if fileManager.fileExists(atPath: direct) {
            return direct
        }
        // Fall back to the first *.app at the volume root.
        if let contents = try? fileManager.contentsOfDirectory(atPath: mountPoint), // try?-ok(fallback path can fail closed to appNotFound)
           let appName = contents.first(where: { $0.hasSuffix(".app") }) {
            return (mountPoint as NSString).appendingPathComponent(appName)
        }
        throw DirectDownloadUpdateInstallError.appNotFoundInDMG
    }

    /// Best-effort code-signature validation. The Ed25519-over-DMG check already
    /// proved authenticity; this catches a corrupt extraction. A hard
    /// `codesign --verify` failure aborts (we fall back to opening the DMG);
    /// the tool being unavailable does not.
    private nonisolated static func validateSignature(at appPath: String) throws {
        let codesign = runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])
        if codesign.status != 0,
           !codesign.combined.localizedCaseInsensitiveContains("command not found") {
            throw DirectDownloadUpdateInstallError.codesignRejected(
                codesign.stderr.isEmpty ? codesign.stdout : codesign.stderr
            )
        }
    }

    // MARK: - Trampoline

    private nonisolated static func spawnTrampoline(
        appPID: Int32,
        sourcePath: String,
        mountPoint: String,
        destinationPath: String
    ) throws {
        let script = makeTrampolineScript(
            appPID: appPID,
            sourcePath: sourcePath,
            mountPoint: mountPoint,
            destinationPath: destinationPath
        )
        let scriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBurnBarUpdateInstall", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let scriptURL = scriptDir.appendingPathComponent("relaunch-\(appPID).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // POSIX_SPAWN_SETSID makes the helper a session leader, fully detached
        // from this dying app — deterministic, not "hope the orphan survives".
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argv = ["/bin/sh", scriptURL.path]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        let result = posix_spawn(&pid, "/bin/sh", nil, &attr, cArgs, environ)
        guard result == 0 else {
            throw DirectDownloadUpdateInstallError.spawnFailed(result)
        }
    }

    /// Generates the relaunch trampoline. Pure + testable. Waits for the app to
    /// exit, kills the bundled daemon (so the new one can rebind the gateway
    /// port), swaps the bundle atomically with a backup + rollback, detaches the
    /// DMG, strips quarantine (the build is notarized+stapled), and relaunches.
    nonisolated static func makeTrampolineScript(
        appPID: Int32,
        sourcePath: String,
        mountPoint: String,
        destinationPath: String
    ) -> String {
        let src = shellSingleQuoted(sourcePath)
        let mount = shellSingleQuoted(mountPoint)
        let dest = shellSingleQuoted(destinationPath)
        let daemon = shellSingleQuoted(destinationPath + "/" + daemonRelativePath)
        return """
        #!/bin/sh
        APP_PID=\(appPID)
        SRC=\(src)
        MOUNT=\(mount)
        DEST=\(dest)
        DAEMON=\(daemon)
        BUNDLE_ID=\(shellSingleQuoted(bundleIdentifier))
        APP_EXECUTABLE=\(shellSingleQuoted(executableName))
        LSREGISTER=\(shellSingleQuoted(launchServicesRegisterPath))
        LOG="$(/usr/bin/dirname "$0")/relaunch.log"
        exec >>"$LOG" 2>&1
        echo "[updater] waiting for PID $APP_PID to exit"
        WAITED=0
        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.2
          WAITED=$((WAITED + 1))
          if [ "$WAITED" -ge 1500 ]; then
            echo "[updater] app still running after ~300s; aborting (terminate vetoed?)"
            /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null
            /bin/rm -f "$0"
            exit 1
          fi
        done
        /usr/bin/pkill -x "$APP_EXECUTABLE" 2>/dev/null || true
        /usr/bin/pkill -f "$DAEMON" 2>/dev/null
        /bin/sleep 0.5
        STAGE="$DEST.new-$$"
        BACKUP="$DEST.bak-$$"
        /bin/rm -rf "$STAGE" "$BACKUP"
        if ! /usr/bin/ditto "$SRC" "$STAGE"; then
          echo "[updater] ditto failed"
          /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null
          /bin/rm -f "$0"
          exit 1
        fi
        if [ -e "$DEST" ]; then
          if ! /bin/mv "$DEST" "$BACKUP"; then
            echo "[updater] could not move the existing app aside; aborting"
            /bin/rm -rf "$STAGE"
            /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null
            /bin/rm -f "$0"
            exit 1
          fi
        fi
        if /bin/mv "$STAGE" "$DEST"; then
          /bin/rm -rf "$BACKUP"
        else
          echo "[updater] swap failed; rolling back"
          /bin/rm -rf "$DEST"
          [ -e "$BACKUP" ] && /bin/mv "$BACKUP" "$DEST"
          /bin/rm -rf "$STAGE"
          /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null
          /bin/rm -f "$0"
          exit 1
        fi
        /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        if [ -x "$LSREGISTER" ]; then
          [ -e "$BACKUP" ] && "$LSREGISTER" -u "$BACKUP" 2>/dev/null || true
          "$LSREGISTER" -f -R -trusted "$DEST" 2>/dev/null || true
          "$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk -v bundle="$BUNDLE_ID" -v dest="$DEST" '
            function flush() {
              if (identifier == bundle && platform == "native" && path != dest && path ~ /\\/OpenBurnBar\\.app$/) {
                print path
              }
              path=""; identifier=""; platform=""
            }
            /^path:[[:space:]]/ {
              path=$0
              sub(/^path:[[:space:]]*/, "", path)
              sub(/[[:space:]]*\\(0x[0-9a-fA-F]+\\).*$/, "", path)
            }
            /^identifier:[[:space:]]/ {
              identifier=$0
              sub(/^identifier:[[:space:]]*/, "", identifier)
            }
            /^platform:[[:space:]]/ {
              platform=$0
              sub(/^platform:[[:space:]]*/, "", platform)
            }
            /^-+$/ { flush() }
            END { flush() }
          ' | while IFS= read -r CANDIDATE; do
            [ -n "$CANDIDATE" ] && "$LSREGISTER" -u "$CANDIDATE" 2>/dev/null || true
          done
          /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | while IFS= read -r CANDIDATE; do
            [ "$CANDIDATE" = "$DEST" ] && continue
            case "$CANDIDATE" in
              */OpenBurnBar.app) "$LSREGISTER" -u "$CANDIDATE" 2>/dev/null || true ;;
            esac
          done
          "$LSREGISTER" -f -R -trusted "$DEST" 2>/dev/null || true
        fi
        echo "[updater] relaunching"
        /usr/bin/open "$DEST"
        /bin/rm -f "$0"
        """
    }

    // MARK: - Helpers

    nonisolated static func isWritableForReplacement(_ path: String) -> Bool {
        let fileManager = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        guard fileManager.isWritableFile(atPath: parent) else { return false }
        if fileManager.fileExists(atPath: path) {
            return fileManager.isDeletableFile(atPath: path)
        }
        return true
    }

    /// Single-quotes a value for safe interpolation into the trampoline shell
    /// script (mount points and paths can contain spaces).
    nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func detach(_ mountPoint: String) {
        _ = runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        var combined: String { stdout + "\n" + stderr }
    }

    private nonisolated static func runProcess(_ launchPath: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: String(describing: error))
        }
        // Drain stdout and stderr concurrently. Reading one to EOF before the
        // other deadlocks if the child fills the unread pipe's buffer (e.g. a
        // verbose codesign/hdiutil failure on stderr). OSAllocatedUnfairLock is
        // genuinely Sendable, so the concurrent closures need no escape hatch.
        let outBox = OSAllocatedUnfairLock(initialState: Data())
        let errBox = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "updater.runProcess.pipes", attributes: .concurrent)
        queue.async(group: group) {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outBox.withLock { $0 = data }
        }
        queue.async(group: group) {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errBox.withLock { $0 = data }
        }
        group.wait()
        process.waitUntilExit()
        let outData = outBox.withLock { $0 }
        let errData = errBox.withLock { $0 }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
#endif
