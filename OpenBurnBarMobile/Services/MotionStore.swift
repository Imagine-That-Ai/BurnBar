import Foundation
import SwiftUI
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(UIKit)
import UIKit

private final class MotionLifecycleObserverBag {
    var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif

// MARK: - MotionStore
//
// Single source of truth for device-tilt parallax. Throttles to 30Hz, auto-pauses
// on background and `accessibilityReduceMotion`, and clamps to ±8° so the parallax
// never feels nauseating. Components consume the published normalized vector
// (range -1.0...1.0 on each axis) via the environment.

@MainActor
@Observable
final class MotionStore {

    /// Normalized roll/pitch in `-1...1`. `(0, 0)` when motion is unavailable.
    var tilt: CGSize = .zero

    /// `true` when active Core Motion updates are streaming.
    private(set) var isActive: Bool = false

    private let maxTiltRadians: Double = 8.0 * .pi / 180.0   // 8° clamp
    private let updateInterval: TimeInterval = 1.0 / 30.0    // 30 Hz

    #if canImport(CoreMotion)
    private let manager = CMMotionManager()
    #endif

    private var subscriberCount: Int = 0
    private var isReduceMotionEnabled = false

    #if canImport(UIKit)
    private var isApplicationActive = UIApplication.shared.applicationState == .active
    private let lifecycleObserverBag = MotionLifecycleObserverBag()
    #endif

    init() {
        installLifecycleObservers()
    }

    /// Increments the subscriber count and starts streaming if needed.
    /// Call from a view's `onAppear` (paired with `release()` in `onDisappear`).
    func acquire(reduceMotion: Bool) {
        subscriberCount += 1
        isReduceMotionEnabled = reduceMotion
        guard subscriberCount == 1 else { return }
        startUpdatesIfAllowed()
    }

    func release() {
        subscriberCount = max(0, subscriberCount - 1)
        if subscriberCount == 0 { stopUpdates() }
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        isReduceMotionEnabled = reduceMotion
        if reduceMotion {
            stopUpdates()
        } else {
            startUpdatesIfAllowed()
        }
    }

    // MARK: - Streaming

    private func startUpdatesIfAllowed() {
        guard subscriberCount > 0, !isReduceMotionEnabled, allowsDeviceMotionUpdates else {
            stopUpdates()
            return
        }
        startUpdates()
    }

    private var allowsDeviceMotionUpdates: Bool {
        #if canImport(UIKit)
        return isApplicationActive
        #else
        return true
        #endif
    }

    private func startUpdates() {
        #if canImport(CoreMotion)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = max(min(motion.attitude.roll, self.maxTiltRadians), -self.maxTiltRadians)
            let pitch = max(min(motion.attitude.pitch, self.maxTiltRadians), -self.maxTiltRadians)
            // Smooth toward the new value to avoid jitter.
            let normalizedX = CGFloat(roll / self.maxTiltRadians)
            let normalizedY = CGFloat(pitch / self.maxTiltRadians)
            let smoothing: CGFloat = 0.18
            self.tilt = CGSize(
                width: self.tilt.width  + (normalizedX - self.tilt.width)  * smoothing,
                height: self.tilt.height + (normalizedY - self.tilt.height) * smoothing
            )
        }
        isActive = true
        #endif
    }

    private func stopUpdates() {
        #if canImport(CoreMotion)
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        #endif
        tilt = .zero
        isActive = false
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObserverBag.observers = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isApplicationActive = true
                    self?.startUpdatesIfAllowed()
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isApplicationActive = false
                    self?.stopUpdates()
                }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isApplicationActive = false
                    self?.stopUpdates()
                }
            }
        ]
        #endif
    }
}

// MARK: - Environment

private struct MotionStoreKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = MotionStore()
}

extension EnvironmentValues {
    var motionStore: MotionStore {
        get { self[MotionStoreKey.self] }
        set { self[MotionStoreKey.self] = newValue }
    }
}

// MARK: - Modifier

/// Applies device-tilt parallax to a view using the shared `MotionStore`.
/// Translation is `tilt * intensity`. Honors Reduce Motion automatically.
struct MotionParallaxModifier: ViewModifier {
    let intensity: CGFloat

    @Environment(\.motionStore) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(
                x: reduceMotion ? 0 : motion.tilt.width * intensity,
                y: reduceMotion ? 0 : motion.tilt.height * intensity
            )
            .onAppear { motion.acquire(reduceMotion: reduceMotion) }
            .onDisappear { motion.release() }
            .onChange(of: reduceMotion) { _, value in
                motion.setReduceMotion(value)
            }
    }
}

extension View {
    /// Tilts the view in response to device motion. Default intensity = 12pt at full tilt.
    func motionParallax(intensity: CGFloat = 12) -> some View {
        modifier(MotionParallaxModifier(intensity: intensity))
    }
}
