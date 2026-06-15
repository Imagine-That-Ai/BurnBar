// `ScreenShareViewerView` — content-rect math, typing focus, panel layout, overlay subviews.
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

extension ScreenShareViewerView {
    func renderedContentRect(in size: CGSize) -> CGRect {
        guard let aspectRatio = coordinator.displayAspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0,
              size.width > 0,
              size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let containerAspect = size.width / size.height
        if containerAspect > aspectRatio {
            let width = size.height * aspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: 0,
                width: width,
                height: size.height
            )
        }

        let height = size.width / aspectRatio
        return CGRect(
            x: 0,
            y: (size.height - height) / 2,
            width: size.width,
            height: height
        )
    }

    func focusTypingBar() {
        guard controlInputEnabled else { return }
        typingFocusTask?.cancel()
        interactionMode = .control
        if isTyping == false {
            isTyping = true
        }
        typingFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard Task.isCancelled == false else { return }
            interactionMode = .control
            if isTyping == false {
                isTyping = true
            }
        }
    }

    func showTapFeedback(at point: CGPoint) {
        withAnimation(.snappy) {
            tapFeedbackPoint = point
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation(.easeOut(duration: 0.18)) {
                tapFeedbackPoint = nil
            }
        }
    }

    func panelDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                panelOffset = clampPanelOffset(
                    panelDragBase + value.translation,
                    in: size
                )
            }
            .onEnded { _ in
                panelDragBase = panelOffset
            }
    }

    func clampPanel(in size: CGSize) {
        panelOffset = clampPanelOffset(panelOffset, in: size)
        panelDragBase = panelOffset
    }

    func clampPanelOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let horizontalLimit = max(0, size.width - (panelCollapsed ? 72 : 112))
        let verticalLimit = max(0, size.height - (panelCollapsed ? 72 : 168))
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), -8),
            height: min(max(proposed.height, 8), verticalLimit)
        )
    }

    @ViewBuilder
    var remoteKeyboardCapture: some View {
        #if canImport(UIKit)
        RemoteKeyboardCaptureView(
            isActive: $isTyping,
            onText: sendTextIntent,
            onKey: { key in
                sendShortcutIntent(key, [])
            }
        )
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }

    var smartTextCoachMark: some View {
        HStack(spacing: 11) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.17, green: 0.79, blue: 0.75))
            VStack(alignment: .leading, spacing: 1) {
                Text("Double-tap to type")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Zoom into the focused field and open the keyboard instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) {
                    smartTextDoubleTapLearned = true
                    smartTextCoachVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    // Material, not glass: this dismiss button is nested inside
                    // the coach-mark's own `.liquidGlassSurface` capsule below,
                    // and glass cannot sample other glass. Material-on-glass
                    // reads cleanly; a nested glass disc would punch through.
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.vertical, 11)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .liquidGlassSurface(in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .frame(maxWidth: 440)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: double-tap a text field to zoom in and type")
    }
}
