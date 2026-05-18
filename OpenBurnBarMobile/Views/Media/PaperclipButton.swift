import SwiftUI

/// iOS chat-input paperclip glyph. Tap presents an action sheet
/// (Photo Library / Files) — Phase 2 reverse direction support for
/// iOS-initiated attachments.
@MainActor
struct PaperclipButton: View {
    @State private var isPresentingPicker: Bool = false
    let onPickPhotoLibrary: () -> Void
    let onPickFiles: () -> Void

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(mercuryGradient)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .confirmationDialog("Attach", isPresented: $isPresentingPicker, titleVisibility: .hidden) {
            Button("Photo Library") { onPickPhotoLibrary() }
            Button("Files") { onPickFiles() }
            Button("Cancel", role: .cancel) { }
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
