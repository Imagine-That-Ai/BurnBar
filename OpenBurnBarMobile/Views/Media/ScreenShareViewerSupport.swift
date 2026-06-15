// Volume-button scroll bridge + CGSize/View helpers for the mirror UI.
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

struct VolumeButtonScrollBridge: UIViewRepresentable {
    let onVolumeStep: @MainActor @Sendable (Double) -> Void

    func makeUIView(context: Context) -> MPVolumeView {
        try? AVAudioSession.sharedInstance().setActive(true)
        let view = MPVolumeView(frame: .zero)
        view.isHidden = true
        context.coordinator.start(onVolumeStep: onVolumeStep)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        context.coordinator.onVolumeStep = onVolumeStep
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onVolumeStep: (@MainActor @Sendable (Double) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume

        func start(onVolumeStep: @escaping @MainActor @Sendable (Double) -> Void) {
            self.onVolumeStep = onVolumeStep
            lastVolume = AVAudioSession.sharedInstance().outputVolume
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let newValue = change.newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let delta = newValue - self.lastVolume
                    self.lastVolume = newValue
                    guard abs(delta) > 0.001 else { return }
                    self.onVolumeStep?(delta > 0 ? -0.28 : 0.28)
                }
            }
        }
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }
}

extension View {
    @ViewBuilder
    func mirrorGlassBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.clear)
                .liquidGlassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
    }
}
