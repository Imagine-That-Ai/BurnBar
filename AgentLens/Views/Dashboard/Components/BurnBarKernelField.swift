import AppKit
import Metal
import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - The usage field, as SwiftUI content
//
// `KernelBackdropView` renders the same idea today as a WebGL2 bundle inside a
// `WKWebView`. This is the same field written as a `[[stitchable]]` fill shader
// (`Theme/Material/BurnBarKernel.metal`), which changes what *kind of object* the
// backdrop is. A `WKWebView` is a sealed rectangle in the compositor: it cannot be
// rasterised by `drawingGroup`, refracted by `layerEffect`, captured by
// `ImageRenderer`, or sampled by macOS 26 `glassEffect`. So every glass plate in the
// app currently floats above a field it cannot see. A `Rectangle().fill(shader)` is
// ordinary content, and all four of those become possible — plus a WebContent process
// and a ~255 KB JS bundle stop shipping.
//
// This is deliberately ADDITIVE. `KernelBackdropView` is untouched; wiring the swap is
// a separate change, and the only thing it needs is a `SwarmColorDriver` — the exact
// value `SwarmWallpaperColorDriverBuilder.driver(...)` already builds for the ember
// swarm.
//
// The split in this file is the same one `BurnBarGlassMaterial.swift` keeps: every
// number the GPU sees is produced by a pure, `Sendable`, view-free value type
// (`BurnBarKernelMath` → `BurnBarKernelUniforms`), so the mapping from *usage* to
// *appearance* is pinned by tests without mounting a window. The view is then a thin
// shell that owns a clock, an occlusion probe and three accessibility switches.

// MARK: - The view

/// BurnBar's living field, drawn by Metal as ordinary SwiftUI content.
///
/// Cost: O(pixels) on the GPU (36 lattice hashes per pixel, constant regardless of
/// provider count), and O(1) on the CPU — about thirty floats per frame, no display
/// list, no allocation, nothing to invalidate.
struct BurnBarKernelField: View {
    /// Live usage. The same value the ember swarm consumes, built by
    /// `SwarmWallpaperColorDriverBuilder.driver(...)`.
    var driver: SwarmColorDriver
    /// Hold the field still for reasons window state cannot see — a dashboard behind
    /// a sheet, a tab that is not front. Occlusion is handled internally.
    var isRunning = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var window = BurnBarKernelWindowState.unknown
    @Environment(\.burnBarWindowState) private var sharedWindowState
    private var windowState: BurnBarKernelWindowState { sharedWindowState ?? window }

    /// The pose the field holds when motion is off.
    ///
    /// Reference-date zero puts every phase at exactly 0, so a frozen field is the
    /// *authored* resting pose rather than whichever frame the clock happened to stop
    /// on — the same contract `PlasmaClock.still` keeps for the plasma surfaces.
    private static let restingDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Resolved once. `MaterialTier` makes the same check for the glass lens: a
    /// headless VM with no Metal device must still draw something.
    private static let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil

    /// Reduce Motion freezes the field — it does not stop drawing it. A paused
    /// `TimelineView` still renders; it just stops asking for new frames.
    private var isAnimating: Bool {
        isRunning && windowState.isVisible && !windowState.isScrolling && !reduceMotion
    }

    /// The frame budget, from the policy the WebGL field already runs to.
    ///
    /// Not a constant 30: `KernelBackdropFramePolicy` presents cinematically against
    /// the display's own refresh, because 30 on a 144 Hz panel lands on an uneven
    /// cadence and strobes. Reusing the policy — rather than picking a number — is
    /// also what keeps the eventual swap from changing the app's power profile.
    private var frameRate: Double {
        KernelBackdropFramePolicy.maxFrameRate(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch,
            refreshHz: windowState.refreshHz
        )
    }

    var body: some View {
        let uniforms = BurnBarKernelMath.uniforms(
            for: driver,
            reduceTransparency: reduceTransparency
        )

        Group {
            if Self.hasMetalDevice {
                // This is atmospheric weather, not a game loop: uncapped frames on a
                // 5K window burn a render core for motion nobody can see.
                TimelineView(.animation(minimumInterval: 1 / frameRate, paused: !isAnimating)) { context in
                    Rectangle()
                        .fill(shader(uniforms, at: reduceMotion ? Self.restingDate : context.date))
                }
            } else {
                Rectangle().fill(
                    LinearGradient(
                        stops: Self.gradientStops(uniforms),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .background {
            if sharedWindowState == nil {
                BurnBarKernelVisibilityProbe { window = $0 }
                    .frame(width: 0, height: 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shader(_ uniforms: BurnBarKernelUniforms, at date: Date) -> Shader {
        let phase = BurnBarKernelMath.phases(at: date.timeIntervalSinceReferenceDate)
        var arguments: [Shader.Argument] = [
            // `.boundingRect` hands the shader the filled shape's rect, so the field
            // needs no `GeometryReader` and costs no layout pass to know its size.
            .boundingRect,
            .float3(phase.x, phase.y, phase.z),
            .float(uniforms.energy),
            .float(uniforms.turbulence),
            .float(uniforms.detail),
            // The page the field settles onto. The adaptive token already resolves
            // light / dark / editorial, and the shader re-derives "is this paper?"
            // from the colour's own luma rather than a flag, so it stays correct for
            // any surface this is ever hosted on.
            .color(DesignSystem.Colors.background)
        ]
        arguments.append(contentsOf: Self.bandArguments(uniforms))

        return Shader(function: ShaderLibrary.default.burnBarUsageField, arguments: arguments)
    }

    /// Packs each ribbon as rgb + its cumulative upper edge.
    ///
    /// Built as an array (rather than spelled out at the call site) so the shader's
    /// fixed arity is satisfied by construction even if `bands` were ever short — a
    /// malformed driver should dim the field, not trap.
    static func bandArguments(_ uniforms: BurnBarKernelUniforms) -> [Shader.Argument] {
        BurnBarKernelMath.bandArguments(uniforms)
    }

    /// The no-Metal substrate: the same ribbons, same order, no optics.
    static func gradientStops(_ uniforms: BurnBarKernelUniforms) -> [Gradient.Stop] {
        let edges = uniforms.edges
        var stops: [Gradient.Stop] = []
        var start = 0.0
        for (index, band) in uniforms.bands.enumerated() {
            let edge = index < edges.count ? edges[index] : 1
            // Place each ribbon at the centre of its own share so the gradient reads
            // as the same weighting the shader draws.
            stops.append(Gradient.Stop(color: band.color.color, location: CGFloat((start + edge) / 2)))
            start = edge
        }
        return stops
    }
}

/// Reports whether the hosting window can actually be seen, and how fast its display
/// refreshes.
///
/// A backdrop behind a fully covered or minimised window is pure waste, and
/// `NSWindow.occlusionState` is the only signal that catches "another app's window is
/// on top of us" — `scenePhase` and `isVisible` both stay happy through it. The policy
/// itself is `OcclusionVisibilityPolicy`, shared verbatim with the WebGL backdrop so
/// the swap cannot change when the field sleeps.
struct BurnBarKernelVisibilityProbe: NSViewRepresentable {
    let onChange: (BurnBarKernelWindowState) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.detach()
    }

    /// A zero-size, hit-test-transparent probe. It exists only to have a `window`.
    final class ProbeView: NSView {
        var onChange: ((BurnBarKernelWindowState) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastPublished: BurnBarKernelWindowState?
        private let scrollingViews = NSHashTable<NSScrollView>.weakObjects()
        private var displayIsAwake = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            // Detached from any window there is nothing to observe, and the policy
            // already answers `false` for a nil window — no second code path needed.
            guard let window else {
                publishCurrentState()
                return
            }
            let names: [NSNotification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                // Dragging to a second display changes the frame budget, not just the
                // geometry — a 60 Hz cadence on a 120 Hz panel is a different loop.
                NSWindow.didChangeScreenNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishCurrentState() }
                }
            }
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    guard let scrollView = notification.object as? NSScrollView else { return }
                    MainActor.assumeIsolated {
                        guard let self,
                              scrollView.window === self.window else { return }
                        if name == NSScrollView.willStartLiveScrollNotification {
                            self.scrollingViews.add(scrollView)
                        } else {
                            self.scrollingViews.remove(scrollView)
                        }
                        self.publishCurrentState()
                    }
                })
            }
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.displayIsAwake = name == NSWorkspace.screensDidWakeNotification
                        self?.publishCurrentState()
                    }
                })
            }
            publishCurrentState()
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observers.removeAll()
            scrollingViews.removeAllObjects()
        }

        private func publishCurrentState() {
            let refresh = window?.screen?.maximumFramesPerSecond ?? 0
            publish(
                BurnBarKernelWindowState(
                    isVisible: displayIsAwake && OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
                    // A detached or off-screen window reports 0; 60 is the safe floor.
                    refreshHz: refresh > 0 ? Double(refresh) : 60,
                    isScrolling: scrollingViews.allObjects.contains { $0.window === window }
                )
            )
        }

        private func publish(_ state: BurnBarKernelWindowState) {
            guard lastPublished != state else { return }
            lastPublished = state
            // Deferred one turn: `viewDidMoveToWindow` runs inside SwiftUI's own
            // update pass, and writing `@State` from there is the "Modifying state
            // during view update" warning.
            Task { @MainActor [weak self] in
                self?.onChange?(state)
            }
        }
    }
}
