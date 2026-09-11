import AppKit
import CryptoKit
import Foundation
import Observation
import OpenBurnBarCore

// Decision logic lives in the line-gated companion files —
// DirectDownloadReleaseMetadata.swift, DirectDownloadArtifactVerifier.swift,
// DirectDownloadUpdatePromptPolicy.swift, UpdateModels.swift. This file is the
// UI/IO orchestration around them: it owns the observable `phase` that the
// SwiftUI update banner renders from, fetches the feed, downloads with live
// progress, verifies, hands off to DirectDownloadUpdateInstaller for the
// mount → swap → relaunch, and dispatches per install channel
// (dmg / homebrew / source).

// MARK: - Update checker

#if !DISTRIBUTION_MAS
/// Channel-aware in-app updater for the notarized DMG distribution and its
/// siblings (Homebrew cask, source/git builds).
///
/// DMG flow: fetch `latest-macos.json` → user clicks Install in the banner →
/// download the DMG with progress → verify sha256 + Ed25519 over the bytes
/// against the pinned `SUPublicEDKey` → mount, ditto-replace
/// `/Applications/OpenBurnBar.app`, and relaunch. Homebrew points at
/// `brew upgrade`; source shows "N commits behind" + a pull/rebuild path.
///
/// Automatic checks run 12s after launch and every 24 hours; `checkForUpdatesNow()`
/// drives the "Check for Updates..." menu item.
@MainActor
@Observable
final class DirectDownloadUpdateChecker {
    static let shared = DirectDownloadUpdateChecker()

    /// The single source of truth every surface renders from.
    private(set) var phase: UpdatePhase = .idle
    /// True only while a user-initiated "Check for Updates" is in flight, so the
    /// Settings button can show inline feedback. Kept separate from `phase` so a
    /// failed check can never leave the banner stuck on a checking state.
    private(set) var isChecking = false
    /// How this copy was installed — decides what "update" means.
    @ObservationIgnored let channel: UpdateChannel

    // User preferences, kept in UserDefaults so the SwiftUI toggles can bind via
    // @AppStorage on the same keys without coupling to the checker.
    static let automaticChecksKey = "updates.automaticChecks"
    static let prereleaseChannelKey = "updates.prereleaseChannel"
    static let oneClickSourceUpdateKey = "updates.oneClickSourceUpdate"

    private static let feedURLKey = "OpenBurnBarDirectUpdateFeedURL"
    private nonisolated static let repoSlug = "Imagine-That-Ai/BurnBar"
    /// Pre-verification defaults key. The legacy checker wrote it before
    /// `runModal`, permanently muting a build after one "Later". It is removed
    /// on start so previously muted machines are prompted again.
    private static let legacyPromptedBuildKey = "OpenBurnBarLastPromptedDirectUpdateBuild"
    private static let defaultFeedURL =
        URL(string: "https://downloads.burnbar.ai/latest-macos.json")!
    private static let releasesPageURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest")!
    private static let recheckInterval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private var hasStartedAutomaticChecks = false
    @ObservationIgnored private var launchCheckTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTimer: Timer?
    @ObservationIgnored private var promptPolicy = DirectDownloadUpdatePromptPolicy()
    @ObservationIgnored private let homebrewChannel = HomebrewUpdateChannel()
    @ObservationIgnored private let sourceChannel = SourceUpdateChannel()
    /// True while a download/verify/install is running, so re-entrant checks
    /// and double-clicks on Install are ignored.
    @ObservationIgnored private var isBusy = false
    /// Last whole-percent we pushed to `phase`, to avoid flooding observation
    /// with sub-percent download ticks.
    @ObservationIgnored private var lastProgressPercent = -1

    private init() {
        channel = UpdateChannelResolver.resolveFromEnvironment()
        // Automatic checks default on; the others default off (UserDefaults'
        // own default). The Settings toggles bind to these same keys.
        UserDefaults.standard.register(defaults: [Self.automaticChecksKey: true])
    }

    // MARK: Preferences (UserDefaults-backed; Settings toggles bind the same keys)

    var automaticChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    var prereleaseChannelEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.prereleaseChannelKey)
    }

    var isOneClickSourceUpdateEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.oneClickSourceUpdateKey)
    }

    // MARK: Scheduling

    func startAutomaticChecks() {
        guard !hasStartedAutomaticChecks,
              !OpenBurnBarRuntime.isRunningTests,
              ProcessInfo.processInfo.environment["OPENBURNBAR_DISABLE_UPDATE_CHECK"] != "1" else {
            return
        }
        guard checksEnabled, automaticChecksEnabled else { return }
        hasStartedAutomaticChecks = true

        UserDefaults.standard.removeObject(forKey: Self.legacyPromptedBuildKey)

        launchCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000) // try?-ok(launch-delay cancellation)
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

    /// Live toggle from Settings: persists the preference and starts or tears
    /// down the scheduler immediately, rather than only taking effect next launch.
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticChecksKey)
        if enabled {
            startAutomaticChecks()
        } else {
            launchCheckTask?.cancel()
            launchCheckTask = nil
            recheckTimer?.invalidate()
            recheckTimer = nil
            // Allow a later re-enable to start the scheduler again.
            hasStartedAutomaticChecks = false
        }
    }

    /// User-initiated "Check for Updates..." — bypasses the "Later" deferral
    /// and surfaces the up-to-date / unreachable states automatic checks keep
    /// silent.
    func checkForUpdatesNow() {
        guard !OpenBurnBarRuntime.isRunningTests else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isChecking = true
            await self.runCheck(userInitiated: true)
            self.isChecking = false
        }
    }

    /// Whether any automatic checking should happen at all. The `dmg`/`homebrew`/
    /// `source` channels each check; `unknown` (a loose build) stays silent
    /// unless explicitly enabled for development/QA.
    private var checksEnabled: Bool {
        if ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_UPDATE_CHECK"] == "1" { return true }
        return channel != .unknown
    }

    /// The channel used for the *check*; an env override lets QA exercise the
    /// DMG flow on a non-installed build.
    private var effectiveChannel: UpdateChannel {
        if channel == .unknown,
           ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_UPDATE_CHECK"] == "1" {
            return .dmg
        }
        return channel
    }

    private func runCheck(userInitiated: Bool) async {
        guard !isBusy else { return }
        switch effectiveChannel {
        case .dmg:
            await runDirectFeedCheck(userInitiated: userInitiated, homebrew: false)
        case .homebrew:
            await runDirectFeedCheck(userInitiated: userInitiated, homebrew: true)
        case .source:
            await runSourceCheck(userInitiated: userInitiated)
        case .unknown:
            if userInitiated { presentManualCheckUnavailableAlert() }
        }
    }

    // MARK: DMG / Homebrew feed check

    private func configuredFeedURL() -> URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: Self.feedURLKey) as? String,
           let url = URL(string: value) {
            return url
        }
        return Self.defaultFeedURL
    }

    private func runDirectFeedCheck(userInitiated: Bool, homebrew: Bool) async {
        do {
            let feedURL = try await resolveFeedURL()
            let release = try await Self.fetchLatestRelease(from: feedURL)
            handleFetchedRelease(release, feedURL: feedURL, userInitiated: userInitiated, homebrew: homebrew)
        } catch {
            NSLog("OpenBurnBar direct update check failed: %@", String(describing: error))
            if userInitiated {
                presentManualCheckUnavailableAlert()
            }
        }
    }

    /// Stable channel uses the pinned feed; the pre-release channel finds the
    /// newest release (including prereleases) via the GitHub Releases API and
    /// uses its `latest-macos.json` asset. Falls back to the stable feed when
    /// the API lookup fails so a rate-limit never blocks stable updates.
    private func resolveFeedURL() async throws -> URL {
        // Pre-release only applies to the DMG channel — Homebrew installs the
        // stable cask regardless, so surfacing a prerelease there would mislead.
        guard prereleaseChannelEnabled, channel == .dmg else { return configuredFeedURL() }
        if let prerelease = try? await Self.resolvePrereleaseFeedURL() { // try?-ok(prerelease lookup falls back to stable feed)
            return prerelease
        }
        return configuredFeedURL()
    }

    private nonisolated static func resolvePrereleaseFeedURL() async throws -> URL {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases?per_page=10")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenBurnBar-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let releases = try JSONDecoder().decode([GitHubReleaseSummary].self, from: data)
        // The API returns newest first; take the first non-draft release that
        // ships the macOS feed asset (prereleases included).
        for release in releases where !release.draft {
            if let asset = release.assets.first(where: { $0.name == "latest-macos.json" }) {
                return asset.browserDownloadURL
            }
        }
        throw URLError(.resourceUnavailable)
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

    private func handleFetchedRelease(
        _ release: DirectDownloadRelease,
        feedURL: URL,
        userInitiated: Bool,
        homebrew: Bool
    ) {
        // A download/verify/install that began while this check was in flight
        // owns `phase` now — don't let a late result clobber it back to .available.
        guard !isBusy else { return }
        guard release.isNewerThanCurrentBundle else {
            phase = .upToDate
            if userInitiated { presentUpToDateAlert() }
            return
        }

        if homebrew {
            // Homebrew never downloads/replaces in-app; it only needs a newer
            // version string to point the user at `brew upgrade`.
            guard userInitiated || promptPolicy.shouldPrompt(for: release, at: Date()) else { return }
            phase = .available(.homebrew(version: release.version))
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

        phase = .available(.directDMG(release))
        // Critical releases escalate with a modal even when no window is open;
        // the banner remains the primary surface for everyone else.
        if release.critical, !userInitiated {
            presentCriticalEscalation(release)
        }
    }

    // MARK: Source / git check

    private func runSourceCheck(userInitiated: Bool) async {
        do {
            let status = try await sourceChannel.fetchStatus()
            guard !isBusy else { return }
            if status.behindBy > 0 {
                phase = .available(.source(status))
            } else {
                phase = .upToDate
                if userInitiated { presentUpToDateAlert() }
            }
        } catch {
            NSLog("OpenBurnBar source update check failed: %@", String(describing: error))
            if userInitiated { presentManualCheckUnavailableAlert() }
        }
    }

    // MARK: Banner actions

    /// "Install Update" — DMG channel only. Downloads with progress, verifies,
    /// and installs + relaunches via DirectDownloadUpdateInstaller.
    func install() {
        guard case let .available(.directDMG(release)) = phase else { return }
        downloadVerifyAndInstall(release)
    }

    /// "Later" — defer the current offer so automatic checks stay quiet until a
    /// newer build (or a critical release) appears.
    func dismiss() {
        if case let .available(offer) = phase {
            switch offer {
            case let .directDMG(release):
                promptPolicy.noteDeferred(build: release.build, at: Date())
            case .homebrew, .source:
                break
            }
        }
        phase = .idle
    }

    /// Homebrew channel CTA — opens Terminal at the upgrade command.
    func updateViaHomebrew() {
        homebrewChannel.runUpgradeInTerminal()
    }

    /// Source channel — open the GitHub compare page for the pending delta.
    func openSourceChanges() {
        if case let .available(.source(status)) = phase, let url = status.compareURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Source channel — copy the manual pull/rebuild command to the pasteboard.
    func copySourceUpdateCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SourceUpdateChannel.manualUpdateCommand, forType: .string)
    }

    /// Source channel — open Terminal at the pull/rebuild command.
    func openSourceUpdateInTerminal() {
        sourceChannel.openManualUpdateInTerminal()
    }

    /// Source channel one-click (opt-in) — run scripts/update-from-source.sh.
    func runSourceUpdate() {
        guard case .available(.source) = phase else { return }
        Task { [weak self] in
            await self?.sourceChannel.runOneClickUpdate { message in
                Task { @MainActor in self?.phase = .failed(message: message) }
            }
        }
    }

    // MARK: Download → verify → install

    private func downloadVerifyAndInstall(_ release: DirectDownloadRelease) {
        guard !isBusy else { return }
        guard let publicKeyBase64 = DirectDownloadArtifactVerifier.bundledPublicKeyBase64() else {
            NSLog("SECURITY: SUPublicEDKey missing from Info.plist; refusing to download update %@.", release.version)
            phase = .failed(message: "This build has no update signing key; cannot verify a download.")
            return
        }
        isBusy = true
        lastProgressPercent = -1
        phase = .downloading(progress: 0)

        let verifier = DirectDownloadArtifactVerifier(publicKeyBase64: publicKeyBase64)
        let destination = Self.downloadDestination(for: release)

        Task { [weak self] in
            do {
                let downloader = DirectDownloadProgressDownloader(
                    expectedLength: release.length,
                    destination: destination
                ) { fraction in
                    Task { @MainActor in self?.reportDownloadProgress(fraction) }
                }
                let fileURL = try await downloader.download(from: release.downloadUrl)

                await MainActor.run { self?.phase = .verifying }
                try verifier.verify(
                    fileAt: fileURL,
                    expectedLength: release.length,
                    expectedSHA256: release.sha256,
                    edSignatureBase64: release.sparkleEdSignature
                )

                await MainActor.run { self?.phase = .installing }
                try await DirectDownloadUpdateInstaller.installAndRelaunch(dmgAt: fileURL)

                // installAndRelaunch terminates the app on a real swap. Reaching
                // here means the packet was already the installed build.
                await MainActor.run {
                    self?.isBusy = false
                    self?.phase = .upToDate
                }
            } catch {
                try? FileManager.default.removeItem(at: destination) // try?-ok(temp cleanup best-effort)
                await MainActor.run {
                    self?.isBusy = false
                    self?.handleInstallFailure(release: release, error: error)
                }
            }
        }
    }

    private func reportDownloadProgress(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded())
        guard percent != lastProgressPercent else { return }
        lastProgressPercent = percent
        phase = .downloading(progress: fraction)
    }

    private func handleInstallFailure(release: DirectDownloadRelease, error: Error) {
        NSLog(
            "OpenBurnBar update install FAILED for %@: %@",
            release.version,
            String(describing: error)
        )
        phase = .failed(message: error.localizedDescription)
        presentVerificationFailureAlert(release: release, error: error)
    }

    private nonisolated static func downloadDestination(for release: DirectDownloadRelease) -> URL {
        // Feed metadata is untrusted (only the DMG bytes are Ed25519-signed), so
        // never let `build` or the URL basename contribute raw path components —
        // a malicious feed could path-traverse out of the temp dir before the
        // file is ever verified. Collapse to one sanitized component + a fixed
        // filename.
        let safeBuild = release.build.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let component = safeBuild.isEmpty ? "pending" : String(safeBuild.prefix(64))
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBurnBarUpdates", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent("OpenBurnBar-update.dmg")
    }

    // MARK: Alerts

    private func presentCriticalEscalation(_ release: DirectDownloadRelease) {
        guard !isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "OpenBurnBar \(release.version) is a critical security update"
        alert.informativeText = "This release fixes a security issue. OpenBurnBar will download the update, verify its cryptographic signature, install it, and relaunch."
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            install()
        } else {
            dismiss()
        }
    }

    private func presentVerificationFailureAlert(release: DirectDownloadRelease, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Update could not be installed"
        alert.informativeText = """
        OpenBurnBar downloaded version \(release.version) but could not verify or install it safely. Nothing on disk was changed.

        \(error.localizedDescription)

        You can download OpenBurnBar manually from the official releases page.
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
        alert.informativeText = "The update source could not be reached or did not contain a verifiable release. Please try again later, or visit the releases page."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPageURL)
        }
    }
}

// MARK: - GitHub Releases (pre-release channel)

private struct GitHubReleaseSummary: Decodable {
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

// MARK: - Progress download

/// Downloads a file to `destination`, reporting fractional progress.
/// `URLSession.shared.download(from:)` exposes no progress and `.shared` cannot
/// take a delegate, so this drives a dedicated session as its own download
/// delegate. It verifies nothing — the caller verifies the bytes afterward.
///
/// AUDIT(@unchecked Sendable): URLSession retains this NSObject delegate; mutable
/// continuation state is resumed once by the delegate callback path (now also
/// NSLock-guarded).
/// sendable-allowlist: foundation-sdk-shim
final class DirectDownloadProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedLength: Int
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var didResume = false

    init(expectedLength: Int, destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedLength = expectedLength
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        guard url.scheme == "https" else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(expectedLength)
        guard total > 0 else { return }
        onProgress(min(1.0, Double(totalBytesWritten) / total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is removed once this returns, so move it
        // synchronously here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            resume(.failure(URLError(.badServerResponse)))
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destination) // try?-ok(pre-move stale cleanup)
            try fileManager.moveItem(at: location, to: destination)
            resume(.success(destination))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(.failure(error)) }
    }

    private func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didResume, let continuation else { lock.unlock(); return }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
#endif
