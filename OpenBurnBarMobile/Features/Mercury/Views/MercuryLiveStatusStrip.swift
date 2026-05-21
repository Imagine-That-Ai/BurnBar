import SwiftUI
import OpenBurnBarMedia

/// Live, interactive status chips below the device name on the Mercury
/// Live screen. Every chip surfaces real data the iPhone already knows
/// (connection phase, advertised capabilities, last-seen, transfer
/// activity, sampled wallpaper color, current mood) and every chip is
/// tappable — taps run actions rather than navigating into a settings
/// page.
///
/// Layout uses a flow wrap so chips re-row on narrow widths and never
/// clip. No card background — the chips float on the screen's existing
/// glass header card.
struct MercuryLiveStatusStrip: View {
    let peer: MercuryPeer
    let phase: MediaControlStreamCoordinator.Phase
    let accent: Color
    let sampledAuto: Color
    let recentTransfersCount: Int
    let inFlightCount: Int
    let moodName: String?
    let canRequestMirror: Bool
    let onReconnect: () -> Void
    let onMirror: () -> Void
    let onCall: () -> Void
    let onSendFile: () -> Void
    let onShowActivity: () -> Void
    let onOpenCustomize: () -> Void

    @State private var lastSeenAbsolute = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(spacing: 8) {
            phaseChip
            capabilitiesChip
            if inFlightCount > 0 {
                inFlightChip
            }
            lastSeenChip
            if recentTransfersCount > 0 {
                activityChip
            }
            wallpaperChip
            if let moodName {
                moodChip(name: moodName)
            }
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    // MARK: Phase

    @ViewBuilder
    private var phaseChip: some View {
        let descriptor = phaseDescriptor
        Button {
            if descriptor.isActionable {
                onReconnect()
            }
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(descriptor.color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(descriptor.shouldPulse && pulse ? 1.25 : 1.0)
                Text(descriptor.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(ChipButtonStyle(tint: descriptor.color))
        .accessibilityLabel(descriptor.accessibility)
    }

    private struct PhaseDescriptor {
        let label: String
        let color: Color
        let shouldPulse: Bool
        let isActionable: Bool
        let accessibility: String
    }

    private var phaseDescriptor: PhaseDescriptor {
        if !peer.isOnline {
            return PhaseDescriptor(
                label: "Offline",
                color: Color(red: 0.85, green: 0.4, blue: 0.4),
                shouldPulse: false,
                isActionable: true,
                accessibility: "Offline — tap to retry"
            )
        }
        switch phase {
        case .live:
            return PhaseDescriptor(
                label: "Live",
                color: Color(red: 0.35, green: 0.85, blue: 0.5),
                shouldPulse: true,
                isActionable: false,
                accessibility: "Mercury live"
            )
        case .dialing:
            return PhaseDescriptor(
                label: "Dialing",
                color: Color(red: 1.0, green: 0.75, blue: 0.3),
                shouldPulse: true,
                isActionable: false,
                accessibility: "Mercury dialing"
            )
        case .reconnecting:
            return PhaseDescriptor(
                label: "Reconnecting",
                color: Color(red: 1.0, green: 0.75, blue: 0.3),
                shouldPulse: true,
                isActionable: true,
                accessibility: "Mercury reconnecting — tap to retry"
            )
        case .failed:
            return PhaseDescriptor(
                label: "Failed",
                color: Color(red: 0.85, green: 0.4, blue: 0.4),
                shouldPulse: false,
                isActionable: true,
                accessibility: "Mercury failed — tap to retry"
            )
        case .stopped:
            return PhaseDescriptor(
                label: "Stopped",
                color: Color(white: 0.6),
                shouldPulse: false,
                isActionable: true,
                accessibility: "Mercury stopped — tap to retry"
            )
        case .idle:
            return PhaseDescriptor(
                label: "Idle",
                color: Color(white: 0.55),
                shouldPulse: false,
                isActionable: true,
                accessibility: "Mercury idle — tap to connect"
            )
        }
    }

    // MARK: Capabilities

    @ViewBuilder
    private var capabilitiesChip: some View {
        HStack(spacing: 0) {
            capabilityIcon(icon: "rectangle.on.rectangle.angled",
                           enabled: canRequestMirror,
                           action: onMirror,
                           label: "Mirror")
            CapabilityDivider()
            capabilityIcon(icon: "phone.fill",
                           enabled: peer.canPlaceCall,
                           action: onCall,
                           label: "Call")
            CapabilityDivider()
            capabilityIcon(icon: "paperclip",
                           enabled: peer.canSendFile,
                           action: onSendFile,
                           label: "Send file")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(chipBackground(tint: accent.opacity(0.35)))
    }

    @ViewBuilder
    private func capabilityIcon(
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void,
        label: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
                .frame(width: 22, height: 18)
                .background(
                    Circle().fill(enabled ? accent.opacity(0.25) : Color.clear)
                        .frame(width: 22, height: 22)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(label)\(enabled ? "" : " unavailable")")
    }

    private struct CapabilityDivider: View {
        var body: some View {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 14)
        }
    }

    // MARK: Last seen

    @ViewBuilder
    private var lastSeenChip: some View {
        Button {
            lastSeenAbsolute.toggle()
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text(lastSeenText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel("Last seen \(lastSeenText)")
    }

    private var lastSeenText: String {
        if lastSeenAbsolute {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: peer.lastSeenAt)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: peer.lastSeenAt, relativeTo: Date())
    }

    // MARK: Activity

    @ViewBuilder
    private var activityChip: some View {
        Button(action: onShowActivity) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text("\(recentTransfersCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(recentTransfersCount == 1 ? "transfer" : "transfers")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel("\(recentTransfersCount) recent transfers — tap to view")
    }

    @ViewBuilder
    private var inFlightChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(pulse ? 360 : 0))
                .animation(reduceMotion ? .none : .linear(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
            Text("\(inFlightCount) in flight")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipBackground(tint: Color.blue.opacity(0.6)))
        .accessibilityLabel("\(inFlightCount) transfers in flight")
    }

    // MARK: Wallpaper / accent dot

    @ViewBuilder
    private var wallpaperChip: some View {
        Button {
            onOpenCustomize()
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(sampledAuto)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                Text("Accent")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel("Accent color — tap to customize")
    }

    // MARK: Mood

    @ViewBuilder
    private func moodChip(name: String) -> some View {
        Button(action: onOpenCustomize) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel("Mood: \(name) — tap to customize")
    }

    // MARK: Chip chrome

    @ViewBuilder
    private func chipBackground(tint: Color = Color.white.opacity(0.08)) -> some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule().fill(Color.white.opacity(0.04))
            )
            .overlay(
                Capsule().stroke(tint, lineWidth: 0.75)
            )
    }
}

/// Shared chip button style — gives every chip the same glass capsule
/// background, a subtle press scale, and a softly-tinted outline.
private struct ChipButtonStyle: ButtonStyle {
    var tint: Color = Color.white.opacity(0.18)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.05)))
                    .overlay(Capsule().stroke(tint, lineWidth: 0.75))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Minimal flow layout used by the chip strip — same shape as the one
/// living in `MercuryBadgePicker.swift` but duplicated here so the two
/// pickers don't share a type and we keep ranking layout focused.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            totalWidth = max(totalWidth, rowWidth)
        }
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
