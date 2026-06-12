import SwiftUI
import OpenBurnBarCore

// MARK: - Change-source TransactionKey
//
// A custom `TransactionKey` that lets the flip animation know whether a value
// change originated from the *user* tapping the toggle, or from the *server*
// state arriving. We only run the frost-flip animation for user-driven flips;
// server-driven updates settle without the dramatic transition so an
// async refresh doesn't make the card spin on its own.

private struct ChangeSourceKey: TransactionKey {
    static let defaultValue: String = "user"
}

extension Transaction {
    var changeSource: String {
        get { self[ChangeSourceKey.self] }
        set { self[ChangeSourceKey.self] = newValue }
    }
}

// MARK: - Yours ↔ Server flip
//
// The signature governance moment: a two-faced card that flips between "What
// stays yours" (deviceOnly facets, sealed) and "What the server sees"
// (serverSees facets). The sealed face adopts Liquid Glass
// (`glassEffect(.regular, in:)`) on macOS 26 and falls back to
// `.ultraThinMaterial` on earlier releases, so the "sealed" state literally
// reads as frosted glass.
//
// Flip duration is driven by the `motionFrostFlipMs` design token.

struct YoursVsServerFlip: View {
    let domain: DataDomain

    /// false = showing "What stays yours" (sealed). true = "What the server sees".
    @State private var showingServer = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var flipDuration: Double {
        (Double(PensieveTokens.motionFrostFlipMs) ?? 520) / 1000
    }

    /// E2E and zero-access domains have a meaningful "stays yours" face; a purely
    /// server-readable domain has no device-only facets, so the flip defaults to
    /// the server face and the toggle is suppressed.
    private var hasYoursFace: Bool { domain.deviceOnly.isEmpty == false }

    var body: some View {
        VStack(spacing: 12) {
            faceToggle
            ZStack {
                if showingServer {
                    serverFace
                        .transition(flipTransition(forward: true))
                } else {
                    yoursFace
                        .transition(flipTransition(forward: false))
                }
            }
            .animation(reduceMotion ? .none : .spring(response: flipDuration, dampingFraction: 0.8), value: showingServer)
        }
        .onAppear { showingServer = hasYoursFace ? false : true }
    }

    // MARK: Toggle

    private var faceToggle: some View {
        HStack(spacing: 0) {
            facePill(title: "What stays yours", system: "lock.shield.fill", selected: showingServer == false, enabled: hasYoursFace) {
                setShowingServer(false)
            }
            facePill(title: "What the server sees", system: "eye.fill", selected: showingServer, enabled: true) {
                setShowingServer(true)
            }
        }
        .padding(3)
        .background(
            Capsule().fill(reduceTransparency ? AnyShapeStyle(DesignSystem.Colors.surface) : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(Capsule().stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.6))
        .accessibilityElement(children: .contain)
    }

    private func facePill(title: String, system: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selected ? Color.white : DesignSystem.Colors.textSecondary)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(domain.encryptionTier.tint.gradient) : AnyShapeStyle(Color.clear))
                )
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// User-initiated flip — tag the transaction so the animation runs.
    private func setShowingServer(_ value: Bool) {
        guard showingServer != value else { return }
        var tx = Transaction()
        tx.changeSource = "user"
        withTransaction(tx) { showingServer = value }
    }

    private func flipTransition(forward: Bool) -> AnyTransition {
        guard reduceMotion == false else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: FlipModifier(angle: forward ? 90 : -90), identity: FlipModifier(angle: 0)),
            removal: .modifier(active: FlipModifier(angle: forward ? -90 : 90), identity: FlipModifier(angle: 0))
        )
    }

    // MARK: Faces

    private var yoursFace: some View {
        faceCard(
            sealed: true,
            title: "Stays on your device",
            subtitle: domain.encryptionTier.explanation,
            facets: domain.deviceOnly,
            facetIcon: "lock.fill",
            accent: PensieveTheme.endToEnd
        )
    }

    private var serverFace: some View {
        faceCard(
            sealed: false,
            title: "What the server can read",
            subtitle: domain.encryptionTier.explanation,
            facets: domain.serverSees,
            facetIcon: "eye.fill",
            accent: domain.encryptionTier.tint
        )
    }

    @ViewBuilder
    private func faceCard(sealed: Bool, title: String, subtitle: String, facets: [String], facetIcon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: sealed ? "lock.shield.fill" : "eye.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
            }
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if facets.isEmpty {
                Text(sealed ? "Nothing here stays device-only." : "The server stores no readable facets for this domain.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                FlowChips(items: facets, icon: facetIcon, tint: accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sealedBackground(sealed: sealed, accent: accent))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(sealed ? 0.45 : 0.30), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func sealedBackground(sealed: Bool, accent: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if reduceTransparency {
            shape.fill(DesignSystem.Colors.surface)
        } else if sealed, #available(macOS 26.0, *) {
            // Liquid Glass for the sealed (frost) state.
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(accent.opacity(0.06))
            }
            .liquidGlassEffect(.regular, in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(accent.opacity(sealed ? 0.08 : 0.05))
            }
        }
    }
}

// MARK: - Flip modifier

private struct FlipModifier: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(abs(angle) > 80 ? 0 : 1)
    }
}

// MARK: - Flow chips

/// A simple wrapping row of facet chips. Used by both flip faces and the
/// inspector's facet lists.
struct FlowChips: View {
    let items: [String]
    let icon: String
    let tint: Color

    var body: some View {
        // Reuses the shared module-level `FlowLayout` (AgentLens/Views/Onboarding/FlowLayout.swift).
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.12)))
                    .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 0.5))
            }
        }
    }
}
