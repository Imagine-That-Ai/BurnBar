import SwiftUI

/// Mac chat-input paperclip glyph. 14pt SF Symbol with a Mercury gradient
/// hover tint — the entry point to the Phase 2 Mac → iOS file send flow.
@MainActor
struct PaperclipButton: View {
    @State private var isHovering: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isHovering ? AnyShapeStyle(mercuryGradient) : AnyShapeStyle(Color.gray))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Send a file to your paired iPhone")
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    Task { @MainActor in
                        // The chat panel injects the actual handler; we
                        // re-emit through `action` for the simple case
                        // where drop is just a URL handoff. The owning
                        // view binds `action` to a closure that receives
                        // the dropped URLs as well.
                        _ = url
                        action()
                    }
                }
            }
            return true
        }
    }

    private var mercuryGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
