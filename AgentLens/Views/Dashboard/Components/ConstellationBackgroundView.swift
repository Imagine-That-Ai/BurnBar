import OpenBurnBarCore
import SwiftUI

/// A calm, slow "Constellation" alternate background for macOS.
///
/// Where ``WebsiteBackgroundView`` runs the energetic, continuously
/// murmurating token-ember swarm, this host reuses the *same*
/// ``SwarmCanvasView`` engine tuned for a quiet, gallery-like cadence: one
/// crest / provider logo at a time materialises — its dots resolving into the
/// mark with each dot carrying the logo's real sampled colour — holds while a
/// per-dot twinkle shimmers across it, then dissolves as the next mark forms.
///
/// Everything here is a thin configuration of the public engine API — no new
/// pixel-sampling code, no edits to ``OpenBurnBarCore``:
///   * `pace: .cinematic` — slow, cinematic drift + a long (~14s) hold so each
///     logo lingers like the web `DotCrestField` reference.
///   * `excludeBrandShapesFromSwarm: true` — collapses the formation cycle to
///     `[swarm → provider logo]` pairs, so a single logo resolves at a time
///     rather than the busy dollar / code / rings / router-flow rotation.
///   * `enableSwarmSparkles: true` — the elegant per-dot twinkle on the held
///     shape.
///   * `motionSpeedMultiplier: 0.55` — extra calm, well within the engine's
///     clamped 0.35…2.5 range.
///   * `isTransparent: true` — the engine paints no backdrop of its own, so the
///     app's themed surface shows through and the constellation reads as an
///     ambient overlay.
///
/// `SwarmCanvasView` already pauses its pace and the shape cycle under
/// `accessibilityReduceMotion`, settling into a calm static frame, so the
/// reduced-motion requirement is satisfied by reusing the engine as-is.
struct ConstellationBackgroundView: View {
    let accent: Color

    var body: some View {
        SwarmCanvasView(
            accent: accent,
            pace: .cinematic,
            isTransparent: true,
            motionSpeedMultiplier: 0.55,
            isAutoCyclingEnabled: true,
            enableSwarmSparkles: true,
            excludeBrandShapesFromSwarm: true,
            rendersAsynchronously: true
        )
        .ignoresSafeArea()
    }
}
