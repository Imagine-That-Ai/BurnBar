// Stream connecting/reconnecting/failed/stopped overlay + visibility policy.
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

struct StreamStateOverlay: View {
    let phase: MediaControlStreamCoordinator.Phase
    let isAwaitingFrame: Bool
    let remoteUnlockActive: Bool
    let usePremiumSOTAUX: Bool
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void

    /// Wall-clock anchor for the "Awaiting first video frame" stretch.
    /// Set the first time the overlay observes `.live + isAwaitingFrame`;
    /// after `Self.awaitingFrameWatchdog` seconds elapse, the overlay
    /// shows the recoverable "Mac isn't sending frames" state, fires one
    /// automatic restart, and leaves manual recovery controls available.
    @State private var awaitingFrameSince: Date?
    @State private var automaticRetryTask: Task<Void, Never>?

    @State private var spinAngle: Double = 0
    @State private var textIndex = 0
    @State private var pulseScale: CGFloat = 1.0
    private static let awaitingFrameWatchdog: TimeInterval = 8.0
    private let statusTexts = [
        "Connecting to paired Mac control stream...",
        "Negotiating VideoToolbox hardware codecs...",
        "Synchronizing GOP keyframes...",
        "Awaiting first video frame..."
    ]

    var body: some View {
        ZStack {
            // Blurred dark overlay behind
            Color.black.opacity(0.6)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                switch phase {
                case .idle, .dialing:
                    connectingContent(title: "Mercury Link", detail: statusTexts[textIndex])

                case .live:
                    if isAwaitingFrame {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            if let since = awaitingFrameSince,
                               context.date.timeIntervalSince(since) >= Self.awaitingFrameWatchdog {
                                stuckFrameContent(stuckSince: since, now: context.date)
                            } else {
                                connectingContent(title: "Mercury Live", detail: "Awaiting first video frame...")
                            }
                        }
                    } else {
                        EmptyView()
                    }

                case .reconnecting(let nextAttemptIn):
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        reconnectingContent(
                            nextAttemptIn: nextAttemptIn,
                            now: context.date
                        )
                    }

                case .failed(let reason):
                    failedContent(reason: reason)

                case .stopped:
                    stoppedContent()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 380)
            .liquidGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            startTextRotation()
            if isAwaitingLiveFrame {
                startAwaitingFrameWatchdog()
            }
        }
        .onChange(of: isAwaitingLiveFrame) { _, awaiting in
            if awaiting {
                startAwaitingFrameWatchdog()
            } else {
                stopAwaitingFrameWatchdog()
            }
        }
        .onDisappear {
            stopAwaitingFrameWatchdog()
        }
    }

    private var isAwaitingLiveFrame: Bool {
        let streamIsLive: Bool
        if case .live = phase {
            streamIsLive = true
        } else {
            streamIsLive = false
        }
        return ScreenShareStreamStateOverlayPolicy.shouldStartAwaitingFrameWatchdog(
            streamIsLive: streamIsLive,
            isAwaitingFrame: isAwaitingFrame,
            remoteUnlockActive: remoteUnlockActive
        )
    }

    // MARK: - Connecting State
    @ViewBuilder
    private func connectingContent(title: String, detail: String) -> some View {
        VStack(spacing: 20) {
            if usePremiumSOTAUX {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1.5)
                        .frame(width: 76, height: 76)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [15, 8])
                        )
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(spinAngle))

                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1.5)
                        .frame(width: 52, height: 52)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.56, green: 0.50, blue: 0.85), Color(red: 0.91, green: 0.44, blue: 0.38)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [10, 6])
                        )
                        .frame(width: 52, height: 52)
                        .rotationEffect(.degrees(-spinAngle * 1.3))

                    Circle()
                        .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulseScale)
                        .opacity(Double(2.0 - pulseScale))
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                pulseScale = 1.6
                            }
                        }

                    Circle()
                        .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                        .frame(width: 10, height: 10)
                }
                .onAppear {
                    withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                }
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 4)
                        .frame(width: 64, height: 64)

                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(spinAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                spinAngle = 360
                            }
                        }
                }
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(detail)
            }
        }
    }

    // MARK: - Reconnecting State
    @ViewBuilder
    private func reconnectingContent(nextAttemptIn: TimeInterval, now: Date) -> some View {
        let elapsed = reconnectAttemptStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let remaining = max(0, nextAttemptIn - elapsed)
        let lastSeenSeconds = lastLiveAt.map { Int(now.timeIntervalSince($0)) }

        VStack(spacing: 20) {
            Image(systemName: "wifi.router.dashed")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .yellow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .orange.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Connection Lost")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(remaining > 0.2
                     ? "Mercury lost contact with the Mac.\nRetrying automatically in \(String(format: "%.1f", remaining))s..."
                     : "Mercury lost contact with the Mac.\nRetrying now...")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                if let reason = lastFailureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 2)
                }

                if let secs = lastSeenSeconds, secs > 0 {
                    Text("Last seen \(formattedRelative(seconds: secs)) ago")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
            }

            VStack(spacing: 12) {
                Button(action: onForceReconnect) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Force Reconnect Now")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func stuckFrameContent(stuckSince: Date, now: Date) -> some View {
        let stuckSeconds = Int(now.timeIntervalSince(stuckSince))
        VStack(spacing: 20) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .yellow.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Mac isn't sending frames")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The control stream is live, but no video has arrived in \(stuckSeconds)s. Mercury is restarting the mirror automatically.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: onRetryRequest) {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Restart Mirror")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onForceReconnect) {
                    Text("Force Reconnect")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    private func formattedRelative(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    // MARK: - Failed State
    @ViewBuilder
    private func failedContent(reason: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .red.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Connection Failed")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(reason)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: onRetryRequest) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Mirror Request")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.red, .orange],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Stopped State
    @ViewBuilder
    private func stoppedContent() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 8) {
                Text("Session Terminated")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The Mac screen sharing session has ended or is unavailable.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            Button(action: onClose) {
                Text("Close Mirror")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    private func startTextRotation() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard phase == .idle || phase == .dialing || (phase == .live && isAwaitingFrame) else { continue }
                withAnimation(.easeInOut(duration: 0.5)) {
                    textIndex = (textIndex + 1) % statusTexts.count
                }
            }
        }
    }

    private func startAwaitingFrameWatchdog() {
        awaitingFrameSince = Date()
        automaticRetryTask?.cancel()
        automaticRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.awaitingFrameWatchdog * 1_000_000_000))
            guard !Task.isCancelled, isAwaitingLiveFrame else { return }
            onRetryRequest()
        }
    }

    private func stopAwaitingFrameWatchdog() {
        awaitingFrameSince = nil
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
    }
}

enum ScreenShareStreamStateOverlayPolicy {
    static func shouldShow(
        displayAspectRatioKnown: Bool,
        streamIsLive: Bool,
        remoteUnlockActive: Bool
    ) -> Bool {
        guard remoteUnlockActive == false else { return false }
        return displayAspectRatioKnown == false || streamIsLive == false
    }

    static func shouldStartAwaitingFrameWatchdog(
        streamIsLive: Bool,
        isAwaitingFrame: Bool,
        remoteUnlockActive: Bool
    ) -> Bool {
        streamIsLive && isAwaitingFrame && remoteUnlockActive == false
    }
}
