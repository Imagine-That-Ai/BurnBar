import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import AVFoundation

/// Phase 7 Mac always-on-top PiP viewer for the iOS camera preview /
/// inbound screen-share feed. Backed by an `NSPanel` configured with
/// `.floating` level + `.canJoinAllSpaces + .fullScreenAuxiliary` so it
/// follows the user across Spaces and floats over fullscreen apps.
@MainActor
final class ScreenShareViewerWindow {
    #if canImport(AppKit)
    private var panel: NSPanel?
    #endif
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func popOut(initialFrame: CGRect = CGRect(x: 60, y: 60, width: 240, height: 320)) {
        #if canImport(AppKit)
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = NSColor.clear

        let host = NSHostingView(rootView: ScreenShareViewerPanelContent(displayLayer: displayLayer))
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        #endif
    }

    func dock() {
        #if canImport(AppKit)
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        #endif
    }
}

private struct ScreenShareViewerPanelContent: View {
    let displayLayer: AVSampleBufferDisplayLayer?

    var body: some View {
        ZStack {
            #if canImport(AppKit)
            if let displayLayer {
                DisplayLayerHost(displayLayer: displayLayer)
                    .ignoresSafeArea()
            } else {
                Color.black
            }
            #else
            Color.black
            #endif
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                        .padding(8)
                }
                Spacer()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(borderGradient, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

#if canImport(AppKit)
private struct DisplayLayerHost: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        view.layer = displayLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        displayLayer.frame = nsView.bounds
    }
}
#endif
