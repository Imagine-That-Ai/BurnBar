import UIKit
import SwiftUI
import OpenBurnBarCore

/// The principal input view controller for the custom iOS keyboard extension.
///
/// Hosts the gorgeous SwiftUI `KeyboardView` inside a `UIHostingController` and
/// wires up system keyboard operations (text input, deleting backward, next keyboard)
/// and data actions (saving keyboard composer snippets, tracking usage frequencies).
///
/// New: spell-check autocorrect suggestions via `SpellCheckService` and
/// haptic feedback via `KeyboardHaptics`.
final class KeyboardViewController: UIInputViewController {
    private var snippets: [TextExpansionSnippet] = []
    private var suggestions: [String] = []
    private var hostingController: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private let spellChecker = SpellCheckService()
    private let predictor = PredictiveTextService()

    private let normalHeight: CGFloat = 260
    private let composeHeight: CGFloat = 345

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        reloadSnippets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardHaptics.prepare()
        reloadSnippets()
    }

    // MARK: - Snippets

    private func reloadSnippets() {
        guard let url = TextExpansionSnapshotStore.snapshotURL(),
              let snapshot = try? TextExpansionSnapshotStore.read(from: url) else {
            snippets = []
            updateHostingView()
            return
        }
        let raw = snapshot.snippets.filter { snippet in
            snippet.mode == .staticText
                && snippet.scope.allows(surface: .iOSKeyboard)
                && snippet.isActive
        }
        if let usageURL = TextExpansionUsageStore.usageURL() {
            let log = TextExpansionUsageStore.read(from: usageURL)
            snippets = TextExpansionUsageStore.rank(raw, using: log)
        } else {
            snippets = raw
        }
        updateHostingView()
    }

    // MARK: - Spell Check

    /// Reads the text before the cursor, extracts the current word,
    /// and computes autocorrect suggestions or predictive next-word suggestions.
    private func refreshSuggestions() {
        let context = textDocumentProxy.documentContextBeforeInput

        // 1. If mid-word: show spell check corrections
        if let currentWord = spellChecker.extractCurrentWord(from: context) {
            let spellSuggestions = spellChecker.suggestions(for: currentWord)
            if !spellSuggestions.isEmpty {
                if spellSuggestions != suggestions {
                    suggestions = spellSuggestions
                    updateHostingView()
                }
                return
            }
        }

        // 2. At a word boundary: show predictive next-word suggestions
        let predictions = predictor.predict(fromContext: context)
        if !predictions.isEmpty {
            if predictions != suggestions {
                suggestions = predictions
                updateHostingView()
            }
            return
        }

        // 3. No suggestions
        if !suggestions.isEmpty {
            suggestions = []
            updateHostingView()
        }
    }

    /// Applies a suggestion — either replacing a misspelled word or inserting a prediction.
    private func applySuggestion(_ suggestion: String) {
        let context = textDocumentProxy.documentContextBeforeInput

        if let currentWord = spellChecker.extractCurrentWord(from: context) {
            // Mid-word: replace the current word with the correction
            for _ in 0..<currentWord.count {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(suggestion + " ")
        } else {
            // At word boundary: insert the predicted word
            textDocumentProxy.insertText(suggestion + " ")
        }

        // Clear suggestions and refresh for next predictions
        suggestions = []
        updateHostingView()
        refreshSuggestions()
    }

    // MARK: - Hosting View

    private func updateHostingView() {
        let keyboardView = KeyboardView(
            snippets: snippets,
            suggestions: suggestions,
            onInsertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
                self?.refreshSuggestions()
            },
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
                self?.refreshSuggestions()
            },
            onAdvanceToNextInputMode: { [weak self] in
                self?.advanceToNextInputMode()
            },
            onSnippetUsed: { [weak self] snippet in
                TextExpansionUsageStore.recordUse(snippetID: snippet.id)
                self?.reloadSnippets()
            },
            onSuggestionSelected: { [weak self] suggestion in
                self?.applySuggestion(suggestion)
            },
            onComposeStateChanged: { [weak self] isComposing in
                self?.setKeyboardHeight(composing: isComposing)
            },
            onReload: { [weak self] in
                self?.reloadSnippets()
            }
        )

        if let hc = hostingController {
            hc.rootView = keyboardView
        } else {
            let hc = UIHostingController(rootView: keyboardView)
            hc.view.backgroundColor = .clear
            addChild(hc)
            view.addSubview(hc.view)
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            let heightC = view.heightAnchor.constraint(equalToConstant: normalHeight)
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: view.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                heightC
            ])
            heightConstraint = heightC
            hc.didMove(toParent: self)
            hostingController = hc
        }
    }

    // MARK: - Height Management

    private func setKeyboardHeight(composing: Bool) {
        let target = composing ? composeHeight : normalHeight
        guard heightConstraint?.constant != target else { return }
        heightConstraint?.constant = target
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.view.superview?.layoutIfNeeded()
        }
    }
}
