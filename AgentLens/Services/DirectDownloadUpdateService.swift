import AppKit
import CryptoKit
import Foundation
import OpenBurnBarCore

// Decision logic lives in the line-gated companion files —
// DirectDownloadReleaseMetadata.swift, DirectDownloadArtifactVerifier.swift,
// DirectDownloadUpdatePromptPolicy.swift. This file is the UI/IO
// orchestration around them (NSAlert prompts, URLSession download, timers,
// NSWorkspace open), which cannot execute under headless XCTest.

// MARK: - Update checker

#if !DISTRIBUTION_MAS
/// Direct-download update channel for the notarized DMG distribution.
///
/// Flow: fetch `latest-macos.json` → user consents via prompt → download the
/// DMG to a temp path in-app → verify sha256 + Ed25519 signature over the
/// downloaded bytes against the pinned `SUPublicEDKey` → only then open the
/// verified local file. A failed verification deletes the download and shows a
/// security-honest error; the unverified file is never opened.
///
/// Checks run 12s after launch and then every 24 hours, plus on demand via
/// `checkForUpdatesNow()` ("Check for Updates..." in the status-item menu).
@MainActor
final class DirectDownloadUpdateChecker {
    static let shared = DirectDownloadUpdateChecker()

    private static let feedURLKey = "OpenBurnBarDirectUpdateFeedURL"
    /// Pre-verification defaults key. The legacy checker wrote it before
    /// `runModal`, permanently muting a build after one "Later". It is removed
    /// on start so previously muted machines are prompted again.
    private static let legacyPromptedBuildKey = "OpenBurnBarLastPromptedDirectUpdateBuild"
    private static let defaultFeedURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json")!
    private static let releasesPageURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest")!
    private static let recheckInterval: TimeInterval = 24 * 60 * 60

    private var hasStartedAutomaticChecks = false
    private var launchCheckTask: Task<Void, Never>?
    private var recheckTimer: Timer?
    private var promptPolicy = DirectDownloadUpdatePromptPolicy()
    /// True while a prompt is on screen or a download/verification is running.
    private var isBusy = false

    private init() {}

    func startAutomaticChecks() {
        guard !hasStartedAutomaticChecks,
              !OpenBurnBarRuntime.isRunningTests,
              ProcessInfo.processInfo.environment["OPENBURNBAR_DISABLE_UPDATE_CHECK"] != "1" else {
            return
        }

        let isInstalledApp = Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/OpenBurnBar.app"
        let isExplicitlyEnabled = ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_UPDATE_CHECK"] == "1"
        guard isInstalledApp || isExplicitlyEnabled else { return }
        hasStartedAutomaticChecks = true

        UserDefaults.standard.removeObject(forKey: Self.legacyPromptedBuildKey)

        launchCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await self?.runCheck(userInitiated: false)
        }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { _ in
            Task { @MainActor in
                await DirectDownloadUpdateChecker.shared.runCheck(userInitiated: false)
            }
        }
        timer.tolerance = Self.recheckInterval / 24
        recheckTimer = timer
    }

    /// User-initiated "Check for Updates..." — bypasses the "Later" deferral
    /// and surfaces the up-to-date / unreachable states that automatic checks
    /// keep silent.
    func checkForUpdatesNow() {
        guard !OpenBurnBarRuntime.isRunningTests else { return }
        Task { [weak self] in
            await self?.runCheck(userInitiated: true)
        }
    }

    private func configuredFeedURL() -> URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: Self.feedURLKey) as? String,
           let url = URL(string: value) {
            return url
        }
        return Self.defaultFeedURL
    }

    private func runCheck(userInitiated: Bool) async {
        guard !isBusy else { return }
        let feedURL = configuredFeedURL()
        do {
            let release = try await Self.fetchLatestRelease(from: feedURL)
            handleFetchedRelease(release, feedURL: feedURL, userInitiated: userInitiated)
        } catch {
            NSLog("OpenBurnBar direct update check failed: %@", String(describing: error))
            if userInitiated {
                presentManualCheckUnavailableAlert()
            }
        }
    }

    private nonisolated static func fetchLatestRelease(from url: URL) async throws -> DirectDownloadRelease {
        guard url.scheme == "https" else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DirectDownloadRelease.self, from: data)
    }

    private func handleFetchedRelease(_ release: DirectDownloadRelease, feedURL: URL, userInitiated: Bool) {
        guard release.isNewerThanCurrentBundle else {
            if userInitiated { presentUpToDateAlert() }
            return
        }
        guard release.hasWellFormedDownloadMetadata(from: feedURL) else {
            NSLog(
                "SECURITY: OpenBurnBar update feed entry for build %@ is malformed (bad scheme, host mismatch, or missing digest/signature); refusing to offer it.",
                release.build
            )
            if userInitiated { presentManualCheckUnavailableAlert() }
            return
        }
        guard DirectDownloadArtifactVerifier.bundledPublicKeyBase64() != nil else {
            // Fail closed: without the pinned key we cannot verify anything we
            // download, so we never offer the update at all.
            NSLog("SECURITY: SUPublicEDKey missing from Info.plist; refusing to offer update %@.", release.version)
            if userInitiated { presentManualCheckUnavailableAlert() }
            return
        }
        guard userInitiated || promptPolicy.shouldPrompt(for: release, at: Date()) else { return }
        presentUpdatePrompt(release)
    }

    private func presentUpdatePrompt(_ release: DirectDownloadRelease) {
        guard !isBusy else { return }
        isBusy = true

        let alert = NSAlert()
        if release.critical {
            alert.messageText = "OpenBurnBar \(release.version) is a critical security update"
            alert.informativeText = "This release fixes a security issue. OpenBurnBar will download the update and verify its cryptographic signature before opening it."
            alert.alertStyle = .critical
        } else {
            alert.messageText = "OpenBurnBar \(release.version) is available"
            alert.informativeText = "A newer notarized build is ready. OpenBurnBar will download the update and verify its cryptographic signature before opening it."
            alert.alertStyle = .informational
        }
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        // Record the decision only AFTER the user responds. (The legacy
        // checker persisted before runModal, which muted the build forever.)
        promptPolicy.noteDeferred(build: release.build, at: Date())
        if response == .alertFirstButtonReturn {
            downloadVerifyAndOpen(release)
        } else {
            isBusy = false
        }
    }

    private func downloadVerifyAndOpen(_ release: DirectDownloadRelease) {
        guard let publicKeyBase64 = DirectDownloadArtifactVerifier.bundledPublicKeyBase64() else {
            NSLog("SECURITY: SUPublicEDKey missing from Info.plist; refusing to download update %@.", release.version)
            isBusy = false
            return
        }
        let verifier = DirectDownloadArtifactVerifier(publicKeyBase64: publicKeyBase64)

        Task { [weak self] in
            let outcome = await Self.downloadAndVerify(release: release, verifier: verifier)
            guard let self else { return }
            self.isBusy = false
            switch outcome {
            case let .success(fileURL):
                NSLog(
                    "OpenBurnBar update %@ downloaded and verified (sha256 + Ed25519 against SUPublicEDKey); opening %@",
                    release.version,
                    fileURL.path
                )
                NSWorkspace.shared.open(fileURL)
            case let .failure(error):
                NSLog(
                    "SECURITY: OpenBurnBar update verification FAILED for %@ — deleted the download, refusing to open it. Error: %@",
                    release.downloadUrl.absoluteString,
                    String(describing: error)
                )
                self.presentVerificationFailureAlert(release: release, error: error)
            }
        }
    }

    /// Downloads the DMG to a temp path and verifies length + SHA-256 +
    /// Ed25519 signature over its bytes. On any failure the downloaded file is
    /// deleted before returning.
    private nonisolated static func downloadAndVerify(
        release: DirectDownloadRelease,
        verifier: DirectDownloadArtifactVerifier
    ) async -> Result<URL, Error> {
        let fileManager = FileManager.default
        let destinationDir = fileManager.temporaryDirectory
            .appendingPathComponent("OpenBurnBarUpdates", isDirectory: true)
            .appendingPathComponent(release.build, isDirectory: true)
        let fileName = release.downloadUrl.lastPathComponent
        let destination = destinationDir.appendingPathComponent(
            fileName.hasSuffix(".dmg") ? fileName : "OpenBurnBar-\(release.version).dmg"
        )

        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: release.downloadUrl)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                try? fileManager.removeItem(at: downloadedURL)
                return .failure(URLError(.badServerResponse))
            }
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: downloadedURL, to: destination)
            try verifier.verify(
                fileAt: destination,
                expectedLength: release.length,
                expectedSHA256: release.sha256,
                edSignatureBase64: release.sparkleEdSignature
            )
            return .success(destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            return .failure(error)
        }
    }

    // MARK: Alerts

    private func presentVerificationFailureAlert(release: DirectDownloadRelease, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Update verification failed"
        alert.informativeText = """
        OpenBurnBar downloaded version \(release.version) but could not verify it against the signing key this app shipped with. The downloaded file has been deleted and was not opened.

        \(error.localizedDescription)

        This can indicate a corrupted download or a tampered update. You can download OpenBurnBar manually from the official releases page.
        """
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPageURL)
        }
    }

    private func presentUpToDateAlert() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date"
        alert.informativeText = "OpenBurnBar \(version) is the newest version available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentManualCheckUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Could not check for updates"
        alert.informativeText = "The update feed could not be reached or did not contain a verifiable release. Please try again later, or visit the releases page."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPageURL)
        }
    }
}
#endif
