/// Present-rate and opacity decisions for the living WebGL kernel.
///
/// Mirrors `packages/gl-engine/src/engine/cinematicClock.ts` (`cinematicPresentFps`)
/// so native `__setMaxFps` and the JS loop cannot disagree.
public enum KernelCinematicPresent {
    public static let dashboardFPS: Double = 30
    public static let performanceGateFPS: Double = 60

    public static func presentFps(refreshHz: Double) -> Double {
        let hz = refreshHz.rounded()
        guard hz.isFinite, hz > 0 else { return dashboardFPS }
        if hz.truncatingRemainder(dividingBy: 30) == 0 { return 30 }
        if hz.truncatingRemainder(dividingBy: 36) == 0 { return 36 }
        if hz.truncatingRemainder(dividingBy: 24) == 0 { return 24 }
        var fps = 36.0
        while fps >= 24 {
            if hz.truncatingRemainder(dividingBy: fps) == 0 { return fps }
            fps -= 1
        }
        return dashboardFPS
    }

    public static func maxFrameRate(isPerformanceGateLaunch: Bool, refreshHz: Double = 60) -> Double {
        if isPerformanceGateLaunch { return performanceGateFPS }
        return presentFps(refreshHz: refreshHz)
    }

    /// Query value for `?maxFps=` so WKWebView boots already capped. Tahoe rAF
    /// is uncapped; waiting for `__setMaxFps` after `didFinish` leaves a
    /// 120 Hz window on first paint. iOS already pins this; macOS must too.
    public static func bootMaxFpsQueryValue(
        isPerformanceGateLaunch: Bool,
        refreshHz: Double = 60
    ) -> String {
        String(Int(maxFrameRate(
            isPerformanceGateLaunch: isPerformanceGateLaunch,
            refreshHz: refreshHz
        )))
    }
}

/// Opaque dashboard chrome covering the kernel is content occlusion.
public enum KernelContentOcclusionPolicy {
    public static let freezeCoverage: Double = 0.95

    public static func isKernelExposed(opaqueCoverage: Double) -> Bool {
        opaqueCoverage < freezeCoverage
    }
}

/// When Liquid Glass clarity is 0 the kernel paints its own field — the
/// WKWebView should be opaque so WindowServer does not alpha-blend it.
public enum KernelWebViewOpacityPolicy {
    public static func isOpaque(clarity: Double) -> Bool {
        clarity <= 0
    }
}
