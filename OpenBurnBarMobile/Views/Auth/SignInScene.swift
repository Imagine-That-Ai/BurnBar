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
    @State private var email = ""
    @State private var password = ""
    @State private var emailExpanded = false
    @State private var emailMode: EmailMode = .signIn
    @FocusState private var focusedField: EmailField?

    private enum EmailField {
        case email, password
    }

    private enum EmailMode: Hashable {
        case signIn, create
    }

    var body: some View {
        ZStack {
            EmberBackdrop(reduceMotion: reduceMotion,
                          reduceTransparency: reduceTransparency)
                .ignoresSafeArea()

            // Outer ScrollView only kicks in when the keyboard or large
            // Dynamic Type push the content past the screen — under normal
            // conditions everything stays vertically + horizontally
            // centered inside a single column.
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: MobileTheme.Spacing.lg)

                        VStack(spacing: 0) {
                            EmberLogo(reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency)
                                .frame(maxWidth: 184)
                                .frame(height: 132)
                                .padding(.bottom, MobileTheme.Spacing.lg)

                            wordmark
                                .padding(.bottom, MobileTheme.Spacing.sm)

                            tagline
                                .padding(.bottom, MobileTheme.Spacing.xl)

                            providerButtons

                            emailDisclosure
                                .padding(.top, MobileTheme.Spacing.md)

                            if let err = authStore.lastError {
                                errorBanner(err)
                                    .padding(.top, MobileTheme.Spacing.lg)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: 360, alignment: .center)

                        Spacer(minLength: MobileTheme.Spacing.lg)

                        privacyFooter
                            .padding(.top, MobileTheme.Spacing.md)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, MobileTheme.Spacing.xl)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? .none : .easeOut(duration: 0.55), value: appeared)
        }
        .dynamicTypeSize(.medium ... .accessibility2)
        .onAppear { appeared = true }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: authStore.lastError)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: emailExpanded)
        .animation(.snappy(duration: 0.2), value: emailMode)
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
            ForEach(authStore.availableProviders.filter { $0 != .email }, id: \.self) { provider in
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
        case .email:
            EmptyView()
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

    /// Tertiary entry point for email auth. Collapsed by default — expands
    /// inline into a compact pane with a Sign in / Create toggle, two
    /// fields, and a single primary action. Keeps the first impression
    /// social-first (Apple/Google) without sacrificing the email path for
    /// users who actually need it.
    @ViewBuilder
    private var emailDisclosure: some View {
        if emailExpanded {
            emailExpandedPane
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
        } else {
            emailCollapsedLink
                .transition(.opacity)
        }
    }

    private var emailCollapsedLink: some View {
        Button {
            emailExpanded = true
            // Defer focus a tick so the field exists by the time we reach for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .email
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text("Sign in with email")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(reduceTransparency ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(authStore.state.inFlightProvider != nil)
        .accessibilityIdentifier("signIn.email.disclose")
        .accessibilityLabel("Sign in with email")
    }

    private var emailExpandedPane: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                EmailModePill(
                    title: "Sign in",
                    isSelected: emailMode == .signIn,
                    action: { emailMode = .signIn }
                )
                .accessibilityIdentifier("signIn.email.mode.signIn")

                EmailModePill(
                    title: "Create",
                    isSelected: emailMode == .create,
                    action: { emailMode = .create }
                )
                .accessibilityIdentifier("signIn.email.mode.create")

                Spacer(minLength: 0)

                Button {
                    emailExpanded = false
                    focusedField = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close email sign-in")
            }

            VStack(spacing: MobileTheme.Spacing.sm) {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .modifier(AuthTextFieldChrome())

                SecureField("Password", text: $password)
                    .textContentType(emailMode == .create ? .newPassword : .password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submitEmail() }
                    .modifier(AuthTextFieldChrome())
            }

            Button(action: submitEmail) {
                EmailButtonLabel(
                    title: emailMode == .signIn ? "Sign in" : "Create account",
                    systemImage: emailMode == .signIn ? "arrow.right" : "envelope.fill",
                    isLoading: authStore.state.inFlightProvider == .email
                )
            }
            .buttonStyle(EmberPressButtonStyle(reduceMotion: reduceMotion,
                                              reduceTransparency: reduceTransparency))
            .disabled(emailActionsDisabled)
            .opacity(emailActionsDisabled ? 0.62 : 1)
            .accessibilityIdentifier(emailMode == .signIn
                                     ? "signIn.email.existing"
                                     : "signIn.email.create")
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(reduceTransparency ? 1 : 0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signIn.email.pane")
    }

    private var emailActionsDisabled: Bool {
        authStore.state.inFlightProvider != nil
            || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.isEmpty
    }

    private func submitEmail() {
        focusedField = nil
        Task {
            switch emailMode {
            case .signIn:
                await authStore.signInWithEmail(email: email, password: password)
            case .create:
                await authStore.createEmailAccount(email: email, password: password)
            }
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

/// Renders the brand SVG as a *lit* flame — the tongues lick upward, the
/// body sways side-to-side as if in a draft, the halo flickers with a
/// multi-frequency rhythm (real fire isn't a sine wave), and faint embers
/// rise through the silhouette.
///
/// The animation is driven by `TimelineView(.animation)` so motion is
/// time-derived rather than spring-driven — gives a continuous, organic
/// flicker instead of a metronomic pulse. The bars at the bottom of the
/// SVG stay anchored while the upper flame stretches and leans, so the
/// "fuel" reads as solid and the "fire" reads as alive.
///
/// Accessibility:
/// - `reduceMotion`: collapses to a still logo + still halo. No flicker,
///   no lean, no embers.
/// - `reduceTransparency`: drops the halo, embers, blur, and plusLighter
///   blends. Just the static SVG.
private struct EmberLogo: View {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    @State private var start = Date()

    var body: some View {
        Group {
            if reduceMotion {
                staticLogo
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let t = context.date.timeIntervalSince(start)
                    animatedLogo(t: t)
                }
            }
        }
        .accessibilityHidden(true) // wordmark provides the label
    }

    // MARK: Static fallback

    private var staticLogo: some View {
        ZStack {
            if !reduceTransparency {
                staticHalo
            }
            logoImage
        }
    }

    private var staticHalo: some View {
        RadialGradient(
            colors: [
                MobileTheme.ember.opacity(0.45),
                MobileTheme.amber.opacity(0.25),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 140
        )
        .blur(radius: 18)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    // MARK: Animated flame

    private func animatedLogo(t: TimeInterval) -> some View {
        // Multi-frequency flicker (sum of three sines) — fire isn't periodic,
        // and stacking incommensurate frequencies gives the eye that "alive"
        // feel without ever quite repeating.
        let f1 = sin(t * 2 * .pi * 0.9)
        let f2 = sin(t * 2 * .pi * 2.1 + 1.7)
        let f3 = sin(t * 2 * .pi * 3.7 + 0.4)
        let flicker  = f1 * 0.5 + f2 * 0.3 + f3 * 0.2          // [-1, 1]
        let intensity = 0.5 + 0.5 * flicker                    // [ 0, 1]

        // Slow lateral lean — like a flame catching a draft. Two slow,
        // incommensurate components so it never lands on the same arc.
        let leanRaw = sin(t * 2 * .pi * 0.45 + 0.9) * 0.6 +
                      sin(t * 2 * .pi * 0.27)        * 0.4
        let leanDegrees = leanRaw * 1.4                        // ±1.4°

        // Vertical lick — anchored at the bottom so the bars stay rooted
        // while the tongues reach up.
        let stretchY: CGFloat = 1.0 + CGFloat(intensity) * 0.07   // up to +7%
        let squeezeX: CGFloat = 1.0 - CGFloat(intensity) * 0.025  // ~conserve

        return ZStack {
            if !reduceTransparency {
                halo(intensity: intensity)
            }

            ZStack {
                logoImage

                if !reduceTransparency {
                    tipGlow(intensity: intensity)
                        .mask(logoImage)

                    embers(t: t)
                        .mask(logoImage)
                }
            }
            .scaleEffect(x: squeezeX, y: stretchY, anchor: .bottom)
            .rotationEffect(.degrees(leanDegrees), anchor: .bottom)
        }
    }

    // MARK: Layers

    private var logoImage: some View {
        Image("AppLogo")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
    }

    /// Warm radial glow behind the flame. Scale + opacity track the flicker
    /// so the room "lights up" with the fire instead of pulsing on its own
    /// rhythm.
    private func halo(intensity: Double) -> some View {
        let scale = 0.95 + intensity * 0.18
        let opacity = 0.55 + intensity * 0.40
        return RadialGradient(
            colors: [
                MobileTheme.ember.opacity(0.55),
                MobileTheme.amber.opacity(0.32),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 150
        )
        .scaleEffect(scale)
        .opacity(opacity)
        .blur(radius: 20)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    /// Brightens the upper portion of the silhouette — flame tips burn
    /// hotter (whiter) than the base. Strength tracks the flicker.
    private func tipGlow(intensity: Double) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.10 + 0.45 * intensity), location: 0.05),
                .init(color: Color.white.opacity(0.20 * intensity),         location: 0.30),
                .init(color: Color.clear,                                   location: 0.65)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    /// Three rising ember sparks confined to the flame body (the upper
    /// 70% of the silhouette — we don't want sparks crawling up through
    /// the bars). Each loops on its own period with a phase offset, so the
    /// sky over the fire never goes still.
    private func embers(t: TimeInterval) -> some View {
        GeometryReader { geo in
            ZStack {
                ember(t: t, period: 1.7, phase: 0.0, xFrac: 0.50, geo: geo,
                      color: MobileTheme.amber)
                ember(t: t, period: 2.1, phase: 0.6, xFrac: 0.42, geo: geo,
                      color: MobileTheme.ember)
                ember(t: t, period: 1.4, phase: 1.2, xFrac: 0.58, geo: geo,
                      color: Color(hex: "FED430"))
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func ember(t: TimeInterval,
                       period: Double,
                       phase: Double,
                       xFrac: CGFloat,
                       geo: GeometryProxy,
                       color: Color) -> some View {
        // Local progress 0 → 1 over `period` seconds.
        let raw = (t + phase).truncatingRemainder(dividingBy: period)
        let progress = CGFloat(raw / period)

        // Travel within the flame body only (top 70% of the SVG bounds —
        // the bottom 30% is the descending bar ladder, where flames don't
        // belong).
        let yStart: CGFloat = 0.65
        let yEnd:   CGFloat = 0.05
        let y = yStart + (yEnd - yStart) * progress

        // Subtle horizontal wobble so the spark drifts as it rises.
        let wobble = CGFloat(sin(Double(progress) * .pi * 2 + phase)) * 0.04
        let x = xFrac + wobble

        // 0 → peak → 0 over the cycle. `sin(progress·π)` gives a clean arc.
        let alpha = max(0, sin(Double(progress) * .pi))

        return Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .blur(radius: 6)
            .opacity(alpha * 0.9)
            .position(x: geo.size.width * x, y: geo.size.height * y)
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
        ZStack {
            HStack(spacing: 12) {
                Image("GoogleLogo")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Continue with Google")
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(MobileTheme.Colors.textSecondary)
                }
                .padding(.trailing, 18)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(MobileTheme.Colors.textPrimary)
        .contentShape(Rectangle())
    }
}

// MARK: - Email Controls

private struct AuthTextFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .tint(MobileTheme.amber)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(MobileTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 1)
            )
    }
}

private struct EmailButtonLabel: View {
    let title: String
    let systemImage: String
    let isLoading: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(MobileTheme.Colors.textPrimary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(MobileTheme.Colors.textPrimary)
        .contentShape(Rectangle())
    }
}

/// Segmented-style pill used by the email pane to switch between Sign in
/// and Create modes. Selected state borrows the brand gradient so the
/// active mode reads at a glance without competing with the primary CTA.
private struct EmailModePill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(isSelected
                                 ? Color.white
                                 : MobileTheme.Colors.textSecondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    Group {
                        if isSelected {
                            Capsule().fill(MobileTheme.primaryGradient)
                        } else {
                            Capsule().fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
                        }
                    }
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
    func createEmailAccount(email: String, password: String) async throws {
        try await signIn(provider: .email)
    }
    func signInWithEmail(email: String, password: String) async throws {
        try await signIn(provider: .email)
    }
    func deleteAccount() async throws {}
    func signOut() throws {}
}
