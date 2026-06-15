// Hidden UITextView keyboard capture + keyboard height/overlap policies.
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

#if canImport(UIKit)
/// Hidden UITextView that captures hardware/soft-keyboard input and reports it
/// as discrete text + key events. Reused by the focused interactive-CLI
/// terminal (`InlineAgentMirrorView`) so typing flows into the live TUI.
struct RemoteKeyboardCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onKey: (String) -> Void
    var keepsFocus: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RemoteKeyboardTextView {
        let textView = RemoteKeyboardTextView(frame: .zero)
        textView.remoteKeyboardDelegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .clear
        textView.tintColor = .clear
        textView.isScrollEnabled = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ uiView: RemoteKeyboardTextView, context: Context) {
        context.coordinator.parent = self
        if isActive {
            if uiView.isFirstResponder == false {
                DispatchQueue.main.async {
                    guard self.isActive else { return }
                    uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
            uiView.text = ""
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, RemoteKeyboardTextViewDelegate {
        var parent: RemoteKeyboardCaptureView
        weak var textView: RemoteKeyboardTextView?

        init(parent: RemoteKeyboardCaptureView) {
            self.parent = parent
        }

        func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(
                    title: "Done",
                    style: .done,
                    target: self,
                    action: #selector(donePressed)
                )
            ]
            toolbar.sizeToFit()
            return toolbar
        }

        @objc private func donePressed() {
            parent.isActive = false
            textView?.resignFirstResponder()
            textView?.text = ""
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            textView.text = ""
            if parent.isActive {
                if parent.keepsFocus {
                    Task { @MainActor [weak textView] in
                        guard self.parent.isActive else { return }
                        textView?.becomeFirstResponder()
                    }
                } else {
                    parent.isActive = false
                }
            }
        }

        func remoteKeyboardTextView(_ textView: RemoteKeyboardTextView, didInsert text: String) {
            textView.text = ""
            switch text {
            case "\n", "\r":
                parent.onKey("Return")
            case "\t":
                parent.onKey("Tab")
            default:
                parent.onText(text)
            }
        }

        func remoteKeyboardTextViewDidDeleteBackward(_ textView: RemoteKeyboardTextView) {
            textView.text = ""
            parent.onKey("Delete")
        }
    }
}

@MainActor
protocol RemoteKeyboardTextViewDelegate: AnyObject {
    func remoteKeyboardTextView(_ textView: RemoteKeyboardTextView, didInsert text: String)
    func remoteKeyboardTextViewDidDeleteBackward(_ textView: RemoteKeyboardTextView)
}

@MainActor
final class RemoteKeyboardTextView: UITextView {
    weak var remoteKeyboardDelegate: RemoteKeyboardTextViewDelegate?

    override var canBecomeFirstResponder: Bool { true }

    override func insertText(_ text: String) {
        remoteKeyboardDelegate?.remoteKeyboardTextView(self, didInsert: text)
    }

    override func deleteBackward() {
        remoteKeyboardDelegate?.remoteKeyboardTextViewDidDeleteBackward(self)
    }
}
#endif

struct KeyboardHeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        #if canImport(UIKit)
        GeometryReader { proxy in
            Color.clear
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    height = ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: frame, viewFrame: proxy.frame(in: .global))
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    height = ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: frame, viewFrame: proxy.frame(in: .global))
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    height = 0
                }
        }
        #else
        Color.clear
        #endif
    }
}

enum ScreenShareKeyboardFramePolicy {
    static func cappedInset(rawOverlap: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        return min(max(rawOverlap, 0), viewportHeight * 0.6)
    }
}

#if canImport(UIKit)
enum ScreenShareKeyboardOverlapPolicy {
    static func overlap(keyboardFrame: CGRect, viewFrame: CGRect) -> CGFloat {
        guard keyboardFrame.width > 0, keyboardFrame.height > 0, viewFrame.width > 0, viewFrame.height > 0 else {
            return 0
        }
        return max(0, min(viewFrame.intersection(keyboardFrame).height, viewFrame.height))
    }
}
#endif
