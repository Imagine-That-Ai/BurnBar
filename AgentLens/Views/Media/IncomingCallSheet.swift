import SwiftUI

/// Phase 5 Mac incoming-call sheet. Full-window NSPanel with mercury
/// hairline, 96pt avatar with mercuryPulse, Decline / Accept buttons.
@MainActor
struct IncomingCallSheet: View {
    let pairedDeviceName: String
    let initial: String
    /// Profile photo of the account requesting access. When present it fills
    /// the avatar circle; while it loads (or if it fails / is `nil`) the view
    /// falls back to the monogram `initial`.
    let avatarURL: URL?
    let subtitle: String
    let actionNoun: String
    let secondaryAcceptTitle: String?
    let secondaryAcceptAccessibilityLabel: String?
    let onAccept: () -> Void
    let onSecondaryAccept: (() -> Void)?
    let onDecline: () -> Void

    init(
        pairedDeviceName: String,
        initial: String,
        avatarURL: URL? = nil,
        subtitle: String = "Pair-debug call",
        actionNoun: String = "call",
        secondaryAcceptTitle: String? = nil,
        secondaryAcceptAccessibilityLabel: String? = nil,
        onAccept: @escaping () -> Void,
        onSecondaryAccept: (() -> Void)? = nil,
        onDecline: @escaping () -> Void
    ) {
        self.pairedDeviceName = pairedDeviceName
        self.initial = initial
        self.avatarURL = avatarURL
        self.subtitle = subtitle
        self.actionNoun = actionNoun
        self.secondaryAcceptTitle = secondaryAcceptTitle
        self.secondaryAcceptAccessibilityLabel = secondaryAcceptAccessibilityLabel
        self.onAccept = onAccept
        self.onSecondaryAccept = onSecondaryAccept
        self.onDecline = onDecline
    }

    @State private var pulseTrigger: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    if !reduceMotion {
                        Circle()
                            .stroke(borderGradient, lineWidth: 1.5)
                            .frame(width: 96, height: 96)
                            .scaleEffect(pulseTrigger ? 1.22 : 1.0)
                            .opacity(pulseTrigger ? 0 : 0.55)
                            .animation(
                                .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                                value: pulseTrigger
                            )
                    }
                    avatar
                    Circle()
                        .strokeBorder(borderGradient, lineWidth: 1.5)
                        .frame(width: 96, height: 96)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Incoming \(actionNoun) from \(pairedDeviceName)")

                Text(pairedDeviceName)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button(role: .destructive) {
                    onDecline()
                } label: {
                    Text("Decline")
                        .frame(width: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
                .accessibilityLabel("Decline \(actionNoun) from \(pairedDeviceName)")
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    onAccept()
                } label: {
                    Text("Accept")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.63, green: 0.67, blue: 0.73))
                .accessibilityLabel("Accept \(actionNoun) from \(pairedDeviceName)")
                .keyboardShortcut(.defaultAction)
            }

            if let secondaryAcceptTitle, let onSecondaryAccept {
                Button {
                    onSecondaryAccept()
                } label: {
                    Text(secondaryAcceptTitle)
                        .frame(width: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.34, green: 0.48, blue: 0.64))
                .accessibilityLabel(
                    secondaryAcceptAccessibilityLabel
                        ?? "\(secondaryAcceptTitle) from \(pairedDeviceName)"
                )
            }
        }
        .padding(40)
        .frame(minWidth: 380, minHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(borderGradient, lineWidth: 1)
                )
        )
        .onAppear {
            if !reduceMotion { pulseTrigger.toggle() }
        }
    }

    /// The 96pt circular avatar: the requester's profile photo when available,
    /// otherwise (and while it loads or fails) the monogram fallback.
    @ViewBuilder
    private var avatar: some View {
        if let avatarURL {
            AsyncImage(
                url: avatarURL,
                transaction: Transaction(animation: .easeIn(duration: 0.25))
            ) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                default:
                    monogram
                        .transition(.opacity)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
        } else {
            monogram
        }
    }

    /// Fallback when there is no photo: the requester's initial, or a generic
    /// person glyph when no usable name was supplied.
    @ViewBuilder
    private var monogram: some View {
        Group {
            if hasInitial {
                Text(initial)
                    .font(.system(size: 36, weight: .semibold))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 34))
            }
        }
        .foregroundStyle(borderGradient)
        .frame(width: 96, height: 96)
        .background(Circle().fill(borderGradient.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private var hasInitial: Bool {
        !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#if DEBUG
#Preview("Mirror request - photo") {
    // Placeholder avatar service, used only to populate the Xcode canvas.
    IncomingCallSheet(
        pairedDeviceName: "Alberto's iPhone",
        initial: "A",
        avatarURL: URL(string: "https://i.pravatar.cc/192"),
        subtitle: "Screen mirror request",
        actionNoun: "mirror request",
        onAccept: {},
        onDecline: {}
    )
    .padding()
}

#Preview("Mirror request - monogram") {
    IncomingCallSheet(
        pairedDeviceName: "Alberto's iPhone",
        initial: "A",
        subtitle: "Screen mirror request",
        actionNoun: "mirror request",
        onAccept: {},
        onDecline: {}
    )
    .padding()
}

#Preview("Mirror + Terminal - no name") {
    IncomingCallSheet(
        pairedDeviceName: "Unknown device",
        initial: "",
        subtitle: "Screen mirror + terminal request",
        actionNoun: "mirror request",
        secondaryAcceptTitle: "Mirror + Terminal",
        onAccept: {},
        onSecondaryAccept: {},
        onDecline: {}
    )
    .padding()
}
#endif
