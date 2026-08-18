import AppKit
import IOKit.ps
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AppDelegate.swift (audit wave 4, item 14).
// Live desktop-wallpaper orchestration: settings/notification observers,
// per-screen wallpaper panels, the system desktop fallback image, power
// (battery) monitoring, and the swarm color-driver sync.
extension AppDelegate {
    // MARK: - Live Wallpaper Orchestration

    func observeDesktopWallpaper() {
        wallpaperEnabledObserver = NotificationCenter.default.addObserver(
            forName: .enableDesktopWallpaperDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWallpaperEnabledChange()
            }
        }

        wallpaperBackgroundObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWallpaperBackgroundChange()
            }
        }

        wallpaperSpeedObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperSpeedDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, ["config_type": "speed"])
                self.sharedWallpaperViewModel.speed = settingsManager.appearance.desktopWallpaperSpeed
            }
        }

        wallpaperProviderGlyphsObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperProviderGlyphsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, [
                    "config_type": "provider_glyphs",
                    "value": .string(AnalyticsBuckets.count(settingsManager.appearance.desktopWallpaperProviderGlyphs.count))
                ])
                self.sharedWallpaperViewModel.providerGlyphs = settingsManager.appearance.desktopWallpaperProviderGlyphs
            }
        }

        wallpaperCycleShapesObserver = NotificationCenter.default.addObserver(
            forName: .cycleShapesScreensaverDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, [
                    "config_type": "cycle_shapes",
                    "value": .bool(settingsManager.appearance.cycleShapesScreensaver)
                ])
                self.sharedWallpaperViewModel.autoCyclesShapes = settingsManager.appearance.cycleShapesScreensaver
            }
        }

        wallpaperSparklesObserver = NotificationCenter.default.addObserver(
            forName: .enableSwarmSparklesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, [
                    "config_type": "sparkles",
                    "value": .bool(settingsManager.appearance.enableSwarmSparkles)
                ])
                self.sharedWallpaperViewModel.enableSwarmSparkles = settingsManager.appearance.enableSwarmSparkles
            }
        }

        wallpaperClickCycleObserver = NotificationCenter.default.addObserver(
            forName: .clickDesktopToCycleSwarmDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, [
                    "config_type": "click_cycle",
                    "value": .bool(settingsManager.appearance.clickDesktopToCycleSwarm)
                ])
                self.sharedWallpaperViewModel.allowsDesktopClickCycle = settingsManager.appearance.clickDesktopToCycleSwarm
            }
        }

        wallpaperExcludeBrandShapesObserver = NotificationCenter.default.addObserver(
            forName: .excludeBrandShapesFromSwarmDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let settingsManager = self.settingsManager else { return }
                Analytics.shared.track(.wallpaperConfigChanged, [
                    "config_type": "exclude_brand",
                    "value": .bool(settingsManager.appearance.excludeBrandShapesFromSwarm)
                ])
                self.sharedWallpaperViewModel.excludeBrandShapesFromSwarm = settingsManager.appearance.excludeBrandShapesFromSwarm
            }
        }
    }

    @objc private func handleWallpaperEnabledChange() {
        Analytics.shared.track(.wallpaperToggled, [
            "enabled": .bool(settingsManager?.appearance.enableDesktopWallpaper ?? false)
        ])
        self.updateWallpaperState()
        self.configureWallpaperActivityPolling()
        self.syncWallpaperColorDriver()
    }

    private func handleWallpaperBackgroundChange() {
        guard let settingsManager else { return }
        Analytics.shared.track(.wallpaperConfigChanged, [
            "config_type": "background",
            "value": .string(settingsManager.appearance.desktopWallpaperBackground.rawValue)
        ])
        sharedWallpaperViewModel.background = settingsManager.appearance.desktopWallpaperBackground
        syncSystemDesktopFallback()
        refreshWallpaperPanels()
    }

    func applyWallpaperAppearance() {
        guard let settingsManager else { return }
        sharedWallpaperViewModel.apply(appearance: settingsManager.appearance)
    }

    private func checkForSystemWallpaperChanges() {
        guard settingsManager?.appearance.enableDesktopWallpaper == true else { return }

        var didCaptureNewOriginal = false

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen),
                  let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
                continue
            }

            // If the user changed the system desktop wallpaper to a non-fallback image,
            // and it is different from the currently cached original wallpaper,
            // capture it as the new original wallpaper that we will restore later,
            // and trigger a re-apply of the themed fallback image.
            if !isOpenBurnBarFallbackURL(currentURL) && currentURL != originalDesktopImageURL(for: displayID) {
                originalDesktopImageURLByScreenID[displayID] = currentURL
                storeOriginalDesktopImageURL(currentURL, for: displayID)
                didCaptureNewOriginal = true
            }
        }

        if didCaptureNewOriginal {
            // Re-apply the selected wallpaper theme to overlay on top of the newly chosen system wallpaper.
            syncSystemDesktopFallback()
        }
    }

    func updateWallpaperState() {
        guard let settingsManager else { return }
        if settingsManager.appearance.enableDesktopWallpaper {
            setupWallpaperPanels()
        } else {
            teardownWallpaperPanels(restoreSystemWallpaper: true)
        }
    }

    private func setupWallpaperPanels() {
        teardownWallpaperPanels(restoreSystemWallpaper: false)
        guard let settingsManager else { return }
        loadWallpaperUsagePresentationIfNeeded()
        sharedWallpaperViewModel.apply(appearance: settingsManager.appearance)
        syncSystemDesktopFallback()
        let screens = NSScreen.screens
        for screen in screens {
            let panel = BurnBarWallpaperPanel(screen: screen, viewModel: sharedWallpaperViewModel)
            panel.orderFrontRegardless()
            wallpaperPanels.append(panel)
        }
    }

    private func refreshWallpaperPanels() {
        for panel in wallpaperPanels {
            panel.orderFrontRegardless()
        }
    }

    func teardownWallpaperPanels(restoreSystemWallpaper: Bool = true) {
        for panel in wallpaperPanels {
            panel.orderOut(self)
            panel.close()
        }
        wallpaperPanels.removeAll()
        if restoreSystemWallpaper {
            restoreOriginalDesktopImages()
        }
    }

    func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChange() {
        if settingsManager?.appearance.enableDesktopWallpaper == true {
            setupWallpaperPanels()
        }
    }

    private func syncSystemDesktopFallback() {
        guard let settingsManager else { return }
        guard settingsManager.appearance.enableDesktopWallpaper else {
            restoreOriginalDesktopImages()
            return
        }

        let background = settingsManager.appearance.desktopWallpaperBackground
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            captureOriginalDesktopImageIfNeeded(for: screen, displayID: displayID)

            do {
                if installedDesktopFallbackByScreenID[displayID] == background,
                   currentDesktopImageIsOpenBurnBarFallback(for: screen) {
                    continue
                }

                let fallbackURL = try renderDesktopFallbackImage(for: background, screen: screen, displayID: displayID)
                try NSWorkspace.shared.setDesktopImageURL(
                    fallbackURL,
                    for: screen,
                    options: [
                        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                        .allowClipping: false
                    ]
                )
                installedDesktopFallbackByScreenID[displayID] = background
            } catch {
                NSLog("OpenBurnBar desktop fallback failed for display \(displayID): \(error.localizedDescription)")
            }
        }
    }

    private func restoreOriginalDesktopImages() {
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen),
                  let originalURL = originalDesktopImageURL(for: displayID),
                  currentDesktopImageIsOpenBurnBarFallback(for: screen) else {
                continue
            }

            do {
                try NSWorkspace.shared.setDesktopImageURL(originalURL, for: screen, options: [:])
                clearStoredOriginalDesktopImageURL(for: displayID)
            } catch {
                NSLog("OpenBurnBar desktop restore failed for display \(displayID): \(error.localizedDescription)")
            }
        }
        installedDesktopFallbackByScreenID.removeAll()
    }

    private func captureOriginalDesktopImageIfNeeded(for screen: NSScreen, displayID: CGDirectDisplayID) {
        if originalDesktopImageURLByScreenID[displayID] == nil,
           let storedURL = storedOriginalDesktopImageURL(for: displayID) {
            originalDesktopImageURLByScreenID[displayID] = storedURL
        }

        guard originalDesktopImageURLByScreenID[displayID] == nil,
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen),
              !isOpenBurnBarFallbackURL(currentURL) else {
            return
        }
        originalDesktopImageURLByScreenID[displayID] = currentURL
        storeOriginalDesktopImageURL(currentURL, for: displayID)
    }

    private func originalDesktopImageURL(for displayID: CGDirectDisplayID) -> URL? {
        if let url = originalDesktopImageURLByScreenID[displayID] {
            return url
        }
        if let storedURL = storedOriginalDesktopImageURL(for: displayID) {
            originalDesktopImageURLByScreenID[displayID] = storedURL
            return storedURL
        }
        return nil
    }

    private func storeOriginalDesktopImageURL(_ url: URL, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(url.absoluteString, forKey: originalDesktopImageURLKey(for: displayID))
    }

    private func storedOriginalDesktopImageURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: originalDesktopImageURLKey(for: displayID)) else {
            return nil
        }
        return URL(string: raw)
    }

    private func clearStoredOriginalDesktopImageURL(for displayID: CGDirectDisplayID) {
        originalDesktopImageURLByScreenID.removeValue(forKey: displayID)
        UserDefaults.standard.removeObject(forKey: originalDesktopImageURLKey(for: displayID))
    }

    private func originalDesktopImageURLKey(for displayID: CGDirectDisplayID) -> String {
        "desktopWallpaper.originalDesktopImageURL.\(displayID)"
    }

    private func currentDesktopImageIsOpenBurnBarFallback(for screen: NSScreen) -> Bool {
        guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { return false }
        return isOpenBurnBarFallbackURL(currentURL)
    }

    private func isOpenBurnBarFallbackURL(_ url: URL) -> Bool {
        let directory = desktopFallbackDirectory()
        return url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    private func desktopFallbackDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("OpenBurnBar/DesktopWallpaperFallbacks", isDirectory: true)
    }

    private func renderDesktopFallbackImage(
        for background: DesktopWallpaperBackground,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) throws -> URL {
        let directory = desktopFallbackDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scale = max(screen.backingScaleFactor, 1)
        let pixelWidth = max(1, Int((screen.frame.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((screen.frame.height * scale).rounded(.up)))
        let fileURL = directory.appendingPathComponent(
            "\(background.rawValue)-\(displayID)-\(pixelWidth)x\(pixelHeight).png",
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "OpenBurnBarWallpaper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create wallpaper bitmap"
            ])
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        NSGradient(colors: desktopFallbackColors(for: background))?.draw(in: rect, angle: -32)
        NSColor.black.withAlphaComponent(0.18).setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OpenBurnBarWallpaper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode wallpaper PNG"
            ])
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func desktopFallbackColors(for background: DesktopWallpaperBackground) -> [NSColor] {
        switch background {
        case .macOSDesktop:
            return [
                NSColor(red: 0.180, green: 0.455, blue: 0.930, alpha: 1),
                NSColor(red: 0.960, green: 0.385, blue: 0.455, alpha: 1),
                NSColor(red: 0.980, green: 0.720, blue: 0.255, alpha: 1)
            ]
        case .midnight:
            return [
                NSColor(red: 0.018, green: 0.026, blue: 0.070, alpha: 1),
                NSColor(red: 0.055, green: 0.145, blue: 0.320, alpha: 1),
                NSColor(red: 0.115, green: 0.260, blue: 0.520, alpha: 1)
            ]
        case .amoledBlack:
            return [.black, NSColor(red: 0.010, green: 0.010, blue: 0.012, alpha: 1), NSColor(red: 0.055, green: 0.055, blue: 0.060, alpha: 1)]
        case .graphite:
            return [
                NSColor(red: 0.105, green: 0.112, blue: 0.128, alpha: 1),
                NSColor(red: 0.270, green: 0.295, blue: 0.330, alpha: 1),
                NSColor(red: 0.475, green: 0.505, blue: 0.545, alpha: 1)
            ]
        case .warmEmber:
            return [
                NSColor(red: 0.115, green: 0.052, blue: 0.030, alpha: 1),
                NSColor(red: 0.470, green: 0.145, blue: 0.020, alpha: 1),
                NSColor(red: 0.920, green: 0.355, blue: 0.055, alpha: 1)
            ]
        case .deepIndigo:
            return [
                NSColor(red: 0.045, green: 0.035, blue: 0.120, alpha: 1),
                NSColor(red: 0.180, green: 0.115, blue: 0.390, alpha: 1),
                NSColor(red: 0.410, green: 0.300, blue: 0.880, alpha: 1)
            ]
        case .auroraTeal:
            return [
                NSColor(red: 0.015, green: 0.045, blue: 0.050, alpha: 1),
                NSColor(red: 0.050, green: 0.180, blue: 0.200, alpha: 1),
                NSColor(red: 0.120, green: 0.380, blue: 0.400, alpha: 1)
            ]
        case .sunsetCrimson:
            return [
                NSColor(red: 0.045, green: 0.018, blue: 0.020, alpha: 1),
                NSColor(red: 0.180, green: 0.055, blue: 0.070, alpha: 1),
                NSColor(red: 0.420, green: 0.115, blue: 0.145, alpha: 1)
            ]
        case .cyberpunkViolet:
            return [
                NSColor(red: 0.030, green: 0.015, blue: 0.045, alpha: 1),
                NSColor(red: 0.150, green: 0.055, blue: 0.220, alpha: 1),
                NSColor(red: 0.380, green: 0.120, blue: 0.520, alpha: 1)
            ]
        case .forestMoss:
            return [
                NSColor(red: 0.015, green: 0.035, blue: 0.020, alpha: 1),
                NSColor(red: 0.055, green: 0.140, blue: 0.080, alpha: 1),
                NSColor(red: 0.150, green: 0.320, blue: 0.180, alpha: 1)
            ]
        case .solarFlare:
            return [
                NSColor(red: 0.050, green: 0.035, blue: 0.015, alpha: 1),
                NSColor(red: 0.200, green: 0.140, blue: 0.055, alpha: 1),
                NSColor(red: 0.480, green: 0.340, blue: 0.120, alpha: 1)
            ]
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    func setupPowerMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        // Event-driven AC <-> battery detection. IOPSCreateLimitedPowerNotification
        // fires only on limited-power transitions, replacing a 5 s polling timer
        // (~17k IOKit snapshots/day at idle). The callback is a C function pointer,
        // so `self` round-trips through an Unmanaged context pointer and hops back
        // to the main actor before touching the wallpaper view model.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                delegate.syncBatteryState()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            batteryNotificationSource = source
        }
        syncBatteryState()
    }

    @objc private func handlePowerStateChange() {
        syncBatteryState()
    }

    private func syncBatteryState() {
        let onBattery = isRunningOnBattery()
        sharedWallpaperViewModel.isBatteryThrottled = onBattery
    }

    private func isRunningOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return Self.isOnBattery(powerSourceDescriptions: descriptions)
    }

    nonisolated static func isOnBattery(powerSourceDescriptions: [[String: Any]]) -> Bool {
        powerSourceDescriptions.contains { description in
            description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        }
    }

    func setupWallpaperObservers() {
        loadWallpaperUsagePresentationIfNeeded()
        observeDataStoreChanges()
        observeDaemonChanges()
        observeWallpaperAgentStatuses()
        configureWallpaperActivityPolling()
        syncWallpaperColorDriver()
    }

    /// The wallpaper is a visible usage surface even when no app window is
    /// open. Hydrate dashboard presentation only when that surface is enabled,
    /// then rebuild its color driver from the real totals.
    private func loadWallpaperUsagePresentationIfNeeded() {
        guard settingsManager?.appearance.enableDesktopWallpaper == true,
              let dataStore else {
            return
        }
        Task { @MainActor [weak self] in
            await dataStore.loadUsagePresentationIfNeeded()
            guard self?.settingsManager?.appearance.enableDesktopWallpaper == true else {
                return
            }
            self?.syncWallpaperColorDriver()
        }
    }

    private func observeDataStoreChanges() {
        guard let dataStore else { return }
        dataStoreObservation = withObservationTracking {
            _ = dataStore.totalCostToday
            _ = dataStore.providerSummaries
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncWallpaperColorDriver()
                self.observeDataStoreChanges()
            }
        }
    }

    private func observeDaemonChanges() {
        guard let daemonManager else { return }
        daemonObservation = withObservationTracking {
            _ = daemonManager.isBusy
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncWallpaperColorDriver()
                self.observeDaemonChanges()
            }
        }
    }

    private func observeWallpaperAgentStatuses() {
        guard wallpaperAgentStatusObserver == nil else { return }
        wallpaperAgentStatusObserver = NotificationCenter.default.addObserver(
            forName: PixelClockAgentStatusStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncWallpaperColorDriver()
            }
        }
    }

    func configureWallpaperActivityPolling() {
        // The legacy 3 s `wallpaperActivityTimer` and 1 s `wallpaperPollTimer`
        // burned cycles every second on every machine that ever enabled the
        // live wallpaper, even when the desktop and agents were idle. They
        // were replaced with three observer-driven sources that fire only on
        // actual state changes, plus a defensive 30 s reconcile so we still
        // catch desktop wallpaper changes that NSWorkspace didn't notify us
        // about (rare, but possible when a third-party tool writes the
        // preferences plist directly).
        //
        //   - `pixelClockAgentStatusStore` already posts
        //     `didChangeNotification` whenever an agent process flips state;
        //     `observeWallpaperAgentStatuses()` (called above) listens to it.
        //   - `NSWorkspace.shared.notificationCenter` posts
        //     `activeSpaceDidChangeNotification` when the user switches
        //     Spaces, which is the most common cause of a wallpaper change.
        //   - `NSApplication.didChangeScreenParametersNotification` covers
        //     resolution / display changes.
        //   - A 30 s `Timer` is the defensive backstop and still runs 30×
        //     less often than the old 1 s poller.
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
        if let observer = wallpaperSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wallpaperSpaceChangeObserver = nil
        }

        guard settingsManager?.appearance.enableDesktopWallpaper == true else { return }

        wallpaperSpaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkForSystemWallpaperChanges()
            }
        }

        // Defensive backstop. 30 s is invisible to humans because the only
        // observable side-effect is re-applying the themed fallback if the
        // captured original wallpaper changed — which the observers above
        // already catch in the common case.
        wallpaperPollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForSystemWallpaperChanges()
            }
        }
    }

    func syncWallpaperColorDriver() {
        wallpaperColorDriverTask?.cancel()
        guard let dataStore else {
            sharedWallpaperViewModel.colorDriver = nil
            return
        }

        let totalCost = dataStore.totalCostToday
        let summaries = dataStore.providerSummaries
        let daemonIsBusy = daemonManager?.isBusy ?? false

        wallpaperColorDriverTask = Task { @MainActor [weak self] in
            let statuses = await PixelClockAgentStatusStore.shared.snapshotIncludingExternalProcesses()
            guard !Task.isCancelled else { return }
            self?.sharedWallpaperViewModel.colorDriver = SwarmWallpaperColorDriverBuilder.driver(
                totalCostToday: totalCost,
                providerSummaries: summaries,
                agentStatuses: statuses,
                daemonIsBusy: daemonIsBusy
            )
        }
    }

    func teardownWallpaperObservers() {
        if let wallpaperEnabledObserver {
            NotificationCenter.default.removeObserver(wallpaperEnabledObserver)
            self.wallpaperEnabledObserver = nil
        }
        if let wallpaperBackgroundObserver {
            NotificationCenter.default.removeObserver(wallpaperBackgroundObserver)
            self.wallpaperBackgroundObserver = nil
        }
        if let wallpaperSpeedObserver {
            NotificationCenter.default.removeObserver(wallpaperSpeedObserver)
            self.wallpaperSpeedObserver = nil
        }
        if let wallpaperProviderGlyphsObserver {
            NotificationCenter.default.removeObserver(wallpaperProviderGlyphsObserver)
            self.wallpaperProviderGlyphsObserver = nil
        }
        if let wallpaperCycleShapesObserver {
            NotificationCenter.default.removeObserver(wallpaperCycleShapesObserver)
            self.wallpaperCycleShapesObserver = nil
        }
        if let wallpaperSparklesObserver {
            NotificationCenter.default.removeObserver(wallpaperSparklesObserver)
            self.wallpaperSparklesObserver = nil
        }
        if let wallpaperClickCycleObserver {
            NotificationCenter.default.removeObserver(wallpaperClickCycleObserver)
            self.wallpaperClickCycleObserver = nil
        }
        if let wallpaperExcludeBrandShapesObserver {
            NotificationCenter.default.removeObserver(wallpaperExcludeBrandShapesObserver)
            self.wallpaperExcludeBrandShapesObserver = nil
        }
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
        if let wallpaperAgentStatusObserver {
            NotificationCenter.default.removeObserver(wallpaperAgentStatusObserver)
            self.wallpaperAgentStatusObserver = nil
        }
        if let wallpaperSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wallpaperSpaceChangeObserver)
            self.wallpaperSpaceChangeObserver = nil
        }
        dataStoreObservation = nil
        daemonObservation = nil
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil
        wallpaperColorDriverTask?.cancel()
        wallpaperColorDriverTask = nil
        if let batteryNotificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batteryNotificationSource, .defaultMode)
            CFRunLoopSourceInvalidate(batteryNotificationSource)
            self.batteryNotificationSource = nil
        }
        NotificationCenter.default.removeObserver(self, name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
}
