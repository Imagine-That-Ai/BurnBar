import Foundation
import SwiftUI

// MARK: - Motion tokens
//
// `DesignSystemTokens` made colour a shared fact: one hex store, four design
// systems resolving from it, so macOS, iOS, the widget, and the console cannot
// drift into four different embers. Motion had no equivalent. Every surface
// reached for `Animation.spring(response:dampingFraction:)` with whatever
// numbers felt right that afternoon, which is why a card settles at one speed on
// Home and a different one three routes away.
//
// These are the product's motion facts, stored as raw numbers rather than as
// `Animation` values, for exactly the reason the colour tokens are hex strings:
// a number crosses a language boundary and a `SwiftUI.Animation` does not.
// Kotlin's `spring(dampingRatio:stiffness:)`, WinUI's `SpringVector3Animation`,
// and a CSS `cubic-bezier` can all be built from the same figures, so the six
// platforms share a motion *identity* while each one expresses it with its own
// system. That is the difference between a shared design language and a
// lowest-common-denominator UI.
//
// The vocabulary is deliberately small, and each entry names a job rather than a
// curve. "Use `settle` when a region resizes" is a rule a reviewer can enforce;
// "use a 0.42 spring" is a number someone will nudge.
//
//   settle   a region changing size or position — the layout itself moving
//   arrive   content entering, with a stagger when it arrives as a group
//   depart   content leaving, faster than it arrived
//   tick     a value changing inside a stable frame
//   pulse    an ambient heartbeat proving the system is live
//
// **Reduce Motion is not a dimmer, it is a different vocabulary.** The bar this
// repo already holds (`RecapMotion`): springs become fades, stagger becomes
// simultaneous. Every helper below has that branch, so honouring the setting is
// the default rather than something each call site remembers.

/// The product's motion constants, in raw units.
///
/// Durations are seconds. Springs are SwiftUI's `response`/`dampingFraction`
/// pair, which converts to the stiffness/damping form other platforms use.
///
/// **Source of truth is `packages/design-tokens/tokens/pensieve.tokens.json`**,
/// under `motion`. That file generates `PensieveTokens` for Swift, Kotlin, C#,
/// WinUI XAML, and CSS, which is how the six platforms share one motion
/// identity. The values are re-declared here as literals rather than parsed from
/// `PensieveTokens` because the generated Swift is compiled into the *app*
/// targets (project.yml:216, :822) and not into this package — so a direct
/// reference would not link. `tokens.test.mjs` asserts these literals against
/// the generated values, which is the same parity-by-test contract the Windows
/// `DashboardLayoutTests` and the Android in-tree token copy already run under:
/// drift fails CI rather than shipping two vocabularies that look alike.
public enum MotionTokens {

    // MARK: Settle — the layout itself moving

    /// Seconds a settle takes to substantially complete.
    public static let settleResponse: Double = 0.42
    /// Damped harder than `standard` on purpose. Overshoot on a *value* reads as
    /// life; overshoot on a *layout* reads as wobble, because the eye tracks the
    /// edge of a plate far more precisely than the middle of a number.
    public static let settleDamping: Double = 0.88

    // MARK: Arrive / depart

    public static let arriveResponse: Double = 0.34
    public static let arriveDamping: Double = 0.80
    /// How far new content rises into place, in points.
    ///
    /// A fixed rise rather than `.move(edge: .top)`, which travels the view's own
    /// height — fine for a chip, a shove for a 400pt card, and the two sitting in
    /// one list arrive at visibly different speeds.
    public static let arriveRise: Double = 18
    /// Scale it starts from, so it reads as approaching rather than sliding.
    public static let arriveScale: Double = 0.97

    /// Leaving is quicker than arriving. A departure the user has already
    /// decided on should not be something they wait for.
    ///
    /// There is no standalone `depart()` curve in Swift: a removal's *shape*
    /// lives in `flow` and its *timing* comes from whatever animation is driving
    /// the layout change, so a separate `Animation` would have had no call site.
    /// The constants stay because `flow` reads `departScale` and the generated
    /// tokens carry both to the platforms that do express departure separately.
    public static let departDuration: Double = 0.16
    public static let departScale: Double = 0.98

    // MARK: Stagger

    /// Delay per item when a group arrives together.
    ///
    /// Matches `RecapReveal`, which is the one place in the repo that already got
    /// stagger right; a second, slightly different stagger would be visible the
    /// moment the two appeared on one screen.
    public static let staggerStep: Double = 0.06
    /// Cap, so the tail of a long list is not still arriving after the user has
    /// started reading the head.
    public static let staggerCap: Double = 0.24

    // MARK: Tick — a value changing in a stable frame

    public static let tickDuration: Double = 0.30

    // MARK: Pulse — ambient proof of life

    /// One breath of an idle heartbeat.
    public static let pulsePeriod: Double = 1.4
    /// Opacity floor and ceiling of that breath. Deliberately shallow: an
    /// ambient signal that swings hard stops being ambient and starts being an
    /// alert, and then a real alert has nowhere louder to go.
    public static let pulseFloor: Double = 0.55
    public static let pulseCeiling: Double = 1.0

    // MARK: Reduce Motion

    /// The single curve every effect collapses to when Reduce Motion is on.
    public static let reducedDuration: Double = 0.18

    /// Per-index delay for a staggered group, respecting Reduce Motion.
    public static func stagger(index: Int, reduceMotion: Bool) -> Double {
        guard reduceMotion == false else { return 0 }
        return min(Double(max(0, index)) * staggerStep, staggerCap)
    }
}

// MARK: - SwiftUI curves

public extension MotionTokens {

    /// A region changing size or position.
    static func settle(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: reducedDuration)
            : .spring(response: settleResponse, dampingFraction: settleDamping)
    }

    /// Content entering, optionally as part of a staggered group.
    static func arrive(index: Int = 0, reduceMotion: Bool) -> Animation {
        guard reduceMotion == false else { return .easeOut(duration: reducedDuration) }
        return .spring(response: arriveResponse, dampingFraction: arriveDamping)
            .delay(stagger(index: index, reduceMotion: false))
    }

    /// A value changing inside a frame that is not moving.
    static func tick(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? reducedDuration : tickDuration)
    }

    /// The ambient heartbeat. `nil` under Reduce Motion — a repeating animation
    /// has no honest reduced form, so it simply does not run.
    static func pulse(reduceMotion: Bool) -> Animation? {
        guard reduceMotion == false else { return nil }
        return .easeInOut(duration: pulsePeriod).repeatForever(autoreverses: true)
    }

    /// The asymmetric transition content uses when the layout reflows around it.
    ///
    /// Asymmetric because arrival and departure are not the same event: arriving
    /// content is news and earns a beat, departing content is a decision already
    /// made and should get out of the way.
    ///
    /// Carries no stagger: a transition describes *shape*, and the delay has to
    /// come from the `Animation` driving it. Pair this with `arrive(index:)` at
    /// the call site when a group should land as a group.
    static func flow(reduceMotion: Bool) -> AnyTransition {
        guard reduceMotion == false else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -arriveRise)
                .combined(with: .opacity)
                .combined(with: .scale(scale: arriveScale, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: departScale, anchor: .top))
        )
    }
}
