// Remote-unlock status overlay + DEBUG simulator harness.
// Extracted from ScreenShareViewerView.swift (behavior-preserving split).
import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct RemoteUnlockStatusOverlay: View {
    let state: HermesRealtimeRelayRemoteUnlockState
    @Binding var password: String
    let savedCredentialAvailable: Bool
    let diagnosticMessage: String?
    let sendCredential: (String) -> Void
    let saveCredential: (String) -> Void
    let sendSavedCredential: () -> Void
    let deleteSavedCredential: () -> Void
    let requestSetup: () -> Void
    let onReconnect: () -> Void
    let onClose: () -> Void
    @State private var isSending = false
    @State private var isSaving = false
    @State private var isSendingSaved = false

    private var canSendCredential: Bool {
        state.capabilities.enabled && state.capabilities.allowsCredentialPaste
    }

    private var canUseSavedCredential: Bool {
        state.capabilities.enabled && state.capabilities.allowsSavedCredentialUnlock
    }

    /// Product-ready presentation for the active blocker, resolved through the
    /// central mapper so the overlay never renders a raw blocker identifier.
    /// `nil` once the Mac can accept a credential (the ready state).
    private var blockerPresentation: RemoteUnlockBlockerPresentation? {
        guard !canSendCredential else { return nil }
        return RemoteUnlockBlockerPresentationMap.presentation(for: state.capabilities)
    }

    private var title: String {
        switch state.lockState {
        case .loginWindow, .rebootLoginWindow: return "Mac Login Window"
        case .securityAgent: return "Mac Authentication Prompt"
        case .screenSaver, .screenLocked: return "Mac Locked"
        case .displaySleeping: return "Mac Display Sleeping"
        case .fastUserSwitching: return "Fast User Switching"
        case .fileVaultPreboot: return "FileVault Preboot"
        case .remoteDesktopCurtain: return "Remote Desktop Curtain"
        case .unknown: return "Mac Lock State Unknown"
        case .unlocked: return "Mac Unlocked"
        }
    }

    /// Short status label under the lock-state title. Action-oriented and free
    /// of raw backend identifiers in every state.
    private var statusSubtitle: String {
        if canSendCredential { return "Remote Unlock ready" }
        return blockerPresentation?.title ?? "Finishing setup"
    }

    private var detail: String {
        if canSendCredential {
            if state.capabilities.certificationStatus == .certified {
                return "Remote Unlock is certified on this Mac. You can click and type while locked; credential entry uses the dedicated remote-unlock lane."
            }
            return "Remote Unlock is ready on this Mac. You can click and type while locked; the first successful locked unlock records hardware certification."
        }
        return blockerPresentation?.message
            ?? "Remote Unlock needs a little more setup on your Mac. Finish it in OpenBurnBar, then reconnect this device."
    }

    /// Picks the right setup affordance from the mapper's recommended action.
    /// Input setup re-runs the Mac install (which also re-surfaces the Privacy
    /// & Security approval), so both input-driver states share one button.
    @ViewBuilder
    private func setupActionButton(for presentation: RemoteUnlockBlockerPresentation) -> some View {
        switch presentation.recommendedAction {
        case .setUpMacInput, .approveInPrivacySettings:
            remoteUnlockActionButton(
                title: presentation.primaryActionTitle ?? "Set up input on Mac",
                systemImage: "keyboard.badge.ellipsis",
                identifier: "remoteUnlock.requestInputSetup",
                action: requestSetup
            )
        case .reconnect, .grantRemoteDesktop:
            remoteUnlockActionButton(
                title: presentation.primaryActionTitle ?? "Reconnect after setup",
                systemImage: "arrow.clockwise",
                identifier: "remoteUnlock.reconnectAfterSetup",
                action: onReconnect
            )
        case .finishOnMac:
            EmptyView()
        }
    }

    private func remoteUnlockActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier(identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: canSendCredential ? "lock.open.display" : "lock.display")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(canSendCredential ? .green : .yellow)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(statusSubtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())
            }

            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            #if DEBUG
            if let presentation = blockerPresentation, !presentation.diagnosticBlockers.isEmpty {
                // Developer diagnostics only — never compiled into release UI.
                // Exact blocker identifiers also land in os.Logger upstream.
                Text("blockers: " + presentation.diagnosticBlockers.joined(separator: ", "))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remoteUnlock.debugBlockers")
            }
            #endif

            if let diagnosticMessage, diagnosticMessage.isEmpty == false {
                Label(diagnosticMessage, systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("remoteUnlock.diagnostic")
            }

            if canSendCredential {
                VStack(alignment: .leading, spacing: 10) {
                    if savedCredentialAvailable, canUseSavedCredential {
                        HStack(spacing: 10) {
                            Button {
                                isSendingSaved = true
                                sendSavedCredential()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    isSendingSaved = false
                                }
                            } label: {
                                Label(isSendingSaved ? "Sending" : "One-tap unlock", systemImage: isSendingSaved ? "checkmark" : "faceid")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.black)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .disabled(isSendingSaved)
                            .accessibilityLabel("Unlock Mac with saved credential")

                            Button(role: .destructive) {
                                deleteSavedCredential()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel("Delete saved Remote Unlock credential")
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Mac password", text: $password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )

                        Button {
                            let credential = password
                            password = ""
                            isSending = true
                            sendCredential(credential)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isSending = false
                            }
                        } label: {
                            Image(systemName: isSending ? "checkmark" : "lock.open")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(password.isEmpty || isSending ? 0.55 : 1)
                        .disabled(password.isEmpty || isSending)
                        .accessibilityLabel("Send Mac password")
                    }

                    if canUseSavedCredential {
                        Button {
                            isSaving = true
                            saveCredential(password)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isSaving = false
                            }
                        } label: {
                            Label(isSaving ? "Saving" : "Save for one-tap unlock", systemImage: isSaving ? "checkmark.shield" : "key.fill")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(password.isEmpty || isSaving ? 0.55 : 1)
                        .disabled(password.isEmpty || isSaving)
                        .accessibilityLabel("Save Mac password for one-tap Remote Unlock")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let presentation = blockerPresentation {
                setupActionButton(for: presentation)
            }
        }
        .padding(16)
        .mirrorGlassBackground(cornerRadius: 18)
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
    }
}

#if DEBUG
struct RemoteUnlockSimulatorHarnessView: View {
    @State private var password = "test-mac-password"
    @State private var savedCredentialAvailable = true
    @State private var status = "Locked Mac Remote Unlock ready"

    private var state: HermesRealtimeRelayRemoteUnlockState {
        HermesRealtimeRelayRemoteUnlockState(
            sessionId: "sim-remote-unlock-session",
            lockState: .loginWindow,
            backend: .openBurnBarVirtualHID,
            capabilities: HermesRealtimeRelayRemoteUnlockCapabilities(
                enabled: true,
                certificationStatus: .certified,
                activeBackend: .openBurnBarVirtualHID,
                supportedBackends: [.openBurnBarVirtualHID],
                supportedLockStates: [.loginWindow, .securityAgent, .screenLocked],
                allowsCredentialPaste: true,
                allowsSavedCredentialUnlock: true,
                credentialRecipientKeyId: "sim-mac-recipient-key",
                credentialRecipientPublicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                credentialEnvelopeAlgorithm: "HPKE-X25519-SHA256-CHACHAPOLY"
            ),
            controlOwnerViewerId: "sim-viewer",
            observedAt: Date()
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.18, green: 0.20, blue: 0.23)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("MacBook Pro", systemImage: "display")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Label("loginwindow", systemImage: "lock.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 92, height: 92)
                        .overlay(
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(.white.opacity(0.70))
                        )
                    Text("Alberto")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Password required")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 18)

                RemoteUnlockStatusOverlay(
                    state: state,
                    password: $password,
                    savedCredentialAvailable: savedCredentialAvailable,
                    diagnosticMessage: status,
                    sendCredential: { credential in
                        status = credential.isEmpty ? "Password missing" : "Typed password queued for loginwindow"
                    },
                    saveCredential: { credential in
                        savedCredentialAvailable = !credential.isEmpty
                        status = credential.isEmpty ? "Password missing" : "One-tap credential available"
                    },
                    sendSavedCredential: {
                        status = "Saved credential queued for loginwindow"
                    },
                    deleteSavedCredential: {
                        savedCredentialAvailable = false
                        status = "Saved credential removed"
                    },
                    requestSetup: {
                        status = "Mac input setup requested"
                    },
                    onReconnect: {
                        status = "Remote Unlock session refreshed"
                    },
                    onClose: {
                        status = "Remote Unlock viewer closed"
                    }
                )

                Text(status)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .accessibilityIdentifier("remoteUnlockHarness.status")
            }
            .padding(18)
        }
        .accessibilityIdentifier("remoteUnlockHarness.root")
    }
}
#endif
