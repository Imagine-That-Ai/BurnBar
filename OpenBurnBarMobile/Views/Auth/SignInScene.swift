import AuthenticationServices
import SwiftUI
import OpenBurnBarCore

// MARK: - SignInScene

/// First impression of the iOS app. Renders the brand logo with a gentle
/// "ember breathing" animation, a warm rising-glow background, and clear
/// "Continue with Apple / Google" buttons. Errors surface as an inline
/// banner directly under the buttons so the user never has to hunt.
///
/// Accessibility:
/// - Honors `accessibilityReduceMotion` (no infinite animations under it).
/// - Honors `accessibilityReduceTransparency` (drops blends + blurs).
/// - All text scales with Dynamic Type up to `.accessibility2`.
/// - Uses Apple's `SignInWithAppleButton` so HIG and VoiceOver are correct.
struct SignInScene: View {
    let authStore: AuthStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        ZStack {
            EmberBackdrop(reduceMotion: reduceMotion,
                          reduceTransparency: reduceTransparency)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                EmberLogo(reduceMotion: reduceMotion,
                          reduceTransparency: reduceTransparency)
                    .frame(maxWidth: 220)
                    .frame(height: 168)
                    .padding(.bottom, MobileTheme.Spacing.xl)

                wordmark
                    .padding(.bottom, MobileTheme.Spacing.sm)

                tagline
                    .padding(.bottom, MobileTheme.Spacing.xxl)

                providerButtons
                    .padding(.horizontal, MobileTheme.Spacing.xl)

                if let err = authStore.lastError {
                    errorBanner(err)
                        .padding(.horizontal, MobileTheme.Spacing.xl)
                        .padding(.top, MobileTheme.Spacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 24)

                privacyFooter
                    .padding(.bottom, MobileTheme.Spacing.lg)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? .none : .easeOut(duration: 0.55), value: appeared)
        }
        .dynamicTypeSize(.medium ... .accessibility2)
        .onAppear { appeared = true }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: authStore.lastError)
    }

    // MARK: - Subviews

    private var wordmark: some View {
        Text("OpenBurnBar")
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .tracking(-0.5)
            .foregroundStyle(MobileTheme.primaryGradient)
            .shadow(color: MobileTheme.ember.opacity(reduceTransparency ? 0 : 0.25),
                    radius: 12, x: 0, y: 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var tagline: some View {
        VStack(spacing: 6) {
            Text("Your AI agents, in your pocket.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.85))
            Text("Sign in with the same account you use on Mac.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var providerButtons: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ForEach(authStore.availableProviders, id: \.self) { provider in
                providerButton(for: provider)
                    .accessibilityIdentifier("signIn.\(provider.rawValue)")
                    .opacity(otherSignInRunning(notMatching: provider) ? 0.6 : 1.0)
                    .disabled(otherSignInRunning(notMatching: provider))
            }
        }
        .animation(.snappy(duration: 0.2), value: authStore.state.inFlightProvider)
    }

    @ViewBuilder
    private func providerButton(for provider: MobileAuthProviderID) -> some View {
        switch provider {
        case .apple:
            // Apple's SwiftUI button handles HIG, dark mode, localization,
            // and VoiceOver out of the box — never hand-roll this control.
            ZStack {
                SignInWithAppleButton(.continue) { request in
                    // The actual nonce / request configuration is owned by
                    // `LiveAuthGateway`; this button only triggers the flow.
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in
                    Task { await authStore.signIn(.apple) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                .shadow(color: Color.black.opacity(reduceTransparency ? 0 : 0.30),
                        radius: 14, x: 0, y: 8)
                .accessibilityHint("Continues sign in with Apple")

                if authStore.state.inFlightProvider == .apple {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(colorScheme == .dark ? .black : .white)
                        .padding(.trailing, 18)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Signing in with Apple")
                }
            }
            .allowsHitTesting(authStore.state.inFlightProvider != .apple)

        case .google:
            Button {
                Task { await authStore.signIn(.google) }
            } label: {
                GoogleButtonLabel(
                    isLoading: authStore.state.inFlightProvider == .google
                )
            }
            .buttonStyle(EmberPressButtonStyle(reduceMotion: reduceMotion,
                                              reduceTransparency: reduceTransparency))
            .accessibilityLabel("Continue with Google")
            .accessibilityHint(authStore.state.inFlightProvider == .google
                               ? "Signing in"
                               : "Continues sign in with your Google account")
        }
    }

    private func otherSignInRunning(notMatching provider: MobileAuthProviderID) -> Bool {
        guard let inFlight = authStore.state.inFlightProvider else { return false }
        return inFlight != provider
    }

    private func errorBanner(_ err: CloudErrorClassification) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MobileTheme.Colors.error)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.label)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(err.recoveryHint)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.error.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.error.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sign-in error. \(err.label). \(err.recoveryHint)")
    }

    private var privacyFooter: some View {
        Text("Encrypted · Local-first · Your stats never leave your account.")
            .font(.system(.caption2, design: .rounded).weight(.medium))
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .multilineTextAlignment(.center)
            .accessibilityLabel("Encrypted, local-first. Your stats never leave your account.")
    }
}

// MARK: - EmberLogo

/// Renders the brand SVG inside a soft ember glow that "breathes" — scale
/// pulses gently and the radial glow ebbs in and out, evoking embers in a
/// fire pit.
///
/// The glow lives behind the logo (NOT inside its mask) so the warm halo
/// is fully visible even though the logo silhouette itself is what shimmers.
private struct EmberLogo: View {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    @State private var pulse = false
    @State private var sweep: CGFloat = -1.2

    var body: some View {
        ZStack {
            // Glow halo — sibling layer (NOT masked) so it stays visible.
            if !reduceTransparency {
                halo
            }

            // The logo itself: SVG resized, with shimmer overlay masked to
            // the logo silhouette so the highlight only travels across the
            // brand mark, never the surrounding canvas.
            ZStack {
                Image("AppLogo")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()

                if !reduceMotion && !reduceTransparency {
                    shimmer
                        .mask(
                            Image("AppLogo")
                                .resizable()
                                .renderingMode(.original)
                                .scaledToFit()
                        )
                }
            }
            .scaleEffect(pulse && !reduceMotion ? 1.04 : 1.00)
            .animation(
                reduceMotion ? .none : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                value: pulse
            )
        }
        .onAppear {
            pulse = true
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false)) {
                sweep = 1.4
            }
        }
        .accessibilityHidden(true) // wordmark provides the label
    }

    private var halo: some View {
        RadialGradient(
            colors: [
                MobileTheme.ember.opacity(0.50),
                MobileTheme.amber.opacity(0.30),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 140
        )
        .scaleEffect(pulse && !reduceMotion ? 1.10 : 0.92)
        .opacity(pulse && !reduceMotion ? 0.95 : 0.55)
        .blur(radius: 18)
        .blendMode(.plusLighter)
        .animation(
            reduceMotion ? .none : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
            value: pulse
        )
        .allowsHitTesting(false)
    }

    /// Diagonal highlight band that travels across the logo silhouette.
    private var shimmer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.0), location: 0.35),
                    .init(color: .white.opacity(0.55), location: 0.50),
                    .init(color: .white.opacity(0.0), location: 0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: w * 1.2, height: h * 1.2)
            .rotationEffect(.degrees(20))
            .offset(x: w * sweep, y: h * sweep * 0.4)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - EmberBackdrop

/// Warm ambient gradient backdrop with two slowly drifting ember orbs.
/// Falls back to a still gradient when Reduce Motion or Reduce Transparency
/// is enabled.
private struct EmberBackdrop: View {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MobileTheme.background,
                    MobileTheme.background,
                    MobileTheme.surface
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if !reduceTransparency {
                emberOrb(
                    color: MobileTheme.ember.opacity(0.55),
                    size: 460,
                    blur: 60,
                    offsetA: CGSize(width: -80, height: -220),
                    offsetB: CGSize(width: -120, height: -180)
                )
                emberOrb(
                    color: MobileTheme.amber.opacity(0.45),
                    size: 420,
                    blur: 70,
                    offsetA: CGSize(width: 100, height: 260),
                    offsetB: CGSize(width: 140, height: 220)
                )
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func emberOrb(color: Color,
                          size: CGFloat,
                          blur: CGFloat,
                          offsetA: CGSize,
                          offsetB: CGSize) -> some View {
        let offset = (animate && !reduceMotion) ? offsetB : offsetA
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.48
                )
            )
            .frame(width: size, height: size)
            .offset(offset)
            .blur(radius: blur)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

// MARK: - GoogleButtonLabel

/// Visual content of the Google button. Lives outside the ButtonStyle so
/// the parent `Button` can drive press / VoiceOver / disabled state.
private struct GoogleButtonLabel: View {
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            GoogleGGlyph()
                .frame(width: 22, height: 22)
            Text("Continue with Google")
                .font(.system(.body, design: .rounded).weight(.semibold))
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(MobileTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(MobileTheme.Colors.textPrimary)
        .contentShape(Rectangle())
    }
}

// MARK: - EmberPressButtonStyle

/// VoiceOver-safe press feedback. We use ButtonStyle (which exposes
/// `configuration.isPressed`) instead of DragGesture so VoiceOver activation
/// continues to work correctly.
private struct EmberPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(MobileTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 1)
            )
            .shadow(
                color: reduceTransparency
                    ? Color.clear
                    : MobileTheme.ember.opacity(configuration.isPressed ? 0.10 : 0.18),
                radius: configuration.isPressed ? 4 : 14,
                x: 0,
                y: configuration.isPressed ? 2 : 8
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(
                reduceMotion ? .none : .spring(response: 0.25, dampingFraction: 0.8),
                value: configuration.isPressed
            )
    }
}

// MARK: - GoogleGGlyph

/// Simplified four-color Google "G" glyph drawn with SwiftUI shapes so we
/// don't have to ship a brand asset. Visual only — `accessibilityHidden`
/// because the parent button already labels itself "Continue with Google".
private struct GoogleGGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.00, to: 0.25)
                .stroke(Color(red: 0.95, green: 0.26, blue: 0.21), lineWidth: 4)
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.25, to: 0.50)
                .stroke(Color(red: 0.98, green: 0.74, blue: 0.02), lineWidth: 4)
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.50, to: 0.75)
                .stroke(Color(red: 0.13, green: 0.69, blue: 0.30), lineWidth: 4)
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.75, to: 1.00)
                .stroke(Color(red: 0.26, green: 0.52, blue: 0.96), lineWidth: 4)
                .rotationEffect(.degrees(-90))

            Rectangle()
                .fill(Color(red: 0.26, green: 0.52, blue: 0.96))
                .frame(width: 9, height: 4)
                .offset(x: 4, y: 0)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - FirebaseUnavailableScene

/// Fallback shown when the app bundle has no Firebase configuration. Same
/// visual language as the sign-in screen, but explains why we can't reach
/// the cloud.
struct FirebaseUnavailableScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            EmberBackdrop(reduceMotion: reduceMotion,
                          reduceTransparency: reduceTransparency)
                .ignoresSafeArea()

            VStack(spacing: MobileTheme.Spacing.xl) {
                EmberLogo(reduceMotion: reduceMotion,
                          reduceTransparency: reduceTransparency)
                    .frame(maxWidth: 180)
                    .frame(height: 132)

                Text("Cloud sync isn't configured")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("This build of OpenBurnBar Mobile is missing its Firebase configuration. Reinstall from the official channel and try again.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .dynamicTypeSize(.medium ... .accessibility2)
    }
}

// MARK: - Previews

#Preview("Sign in") {
    SignInScene(authStore: AuthStore(gateway: PreviewAuthGateway()))
}

#Preview("Sign in — error") {
    let store = AuthStore(gateway: PreviewAuthGateway(throwsOn: .google))
    return SignInScene(authStore: store)
        .task {
            await store.signIn(.google)
        }
}

#Preview("Sign in — light") {
    SignInScene(authStore: AuthStore(gateway: PreviewAuthGateway()))
        .preferredColorScheme(.light)
}

#Preview("Firebase unavailable") {
    FirebaseUnavailableScene()
}

// MARK: - Preview gateway

@MainActor
private final class PreviewAuthGateway: AuthGateway {
    let throwsOn: MobileAuthProviderID?

    init(throwsOn: MobileAuthProviderID? = nil) {
        self.throwsOn = throwsOn
    }

    var availableProviders: [MobileAuthProviderID] { [.apple, .google] }
    var isFirebaseAvailable: Bool { true }
    var currentIdentity: MobileAuthIdentity? { nil }
    func observe(onChange: @escaping @MainActor (MobileAuthIdentity?) -> Void) {}
    func signIn(provider: MobileAuthProviderID) async throws {
        try? await Task.sleep(nanoseconds: 600_000_000)
        if provider == throwsOn {
            throw CloudGatewayError.classified(.networkUnavailable)
        }
    }
    func signOut() throws {}
}
