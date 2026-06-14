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

    /// Darwin notification name — must match `MobileTextExpansionStore.snippetsUpdatedNotification`
    private static let snippetsUpdatedNotification = "com.openburnbar.snippets.updated" as CFString

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        reloadSnippets()
        registerForSnippetUpdates()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardHaptics.prepare()
        reloadSnippets()
    }

    // MARK: - Real-Time Snippet Updates

    /// Registers a Darwin notification observer so the keyboard reloads
    /// snippets immediately when the iOS app writes new data to the App Group.
    private func registerForSnippetUpdates() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // The `observer` pointer is `self` cast to raw — used to route the C callback.
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                vc.reloadSnippets()
            },
            KeyboardViewController.snippetsUpdatedNotification,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterForSnippetUpdates() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(Self.snippetsUpdatedNotification), nil)
    }

    deinit {
        // CFNotificationCenter observers must be removed manually
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - App Group Data Protection (T-IOS-01)

    /// Hardens every App Group file the keyboard writes so a snippet/usage write
    /// from the extension lands with `.completeUnlessOpen` + no backup, matching
    /// the app's `MobileDataProtectionBootstrap` posture. The extension has no
    /// launch hook of its own, so it protects the shared container + its own
    /// files inline after each write. Best-effort; never blocks input.
    private func protectSharedAppGroupFiles() {
        AppGroupDataProtection.protectContainer(
            appGroupIdentifier: TextExpansionSnapshotStore.appGroupIdentifier
        )
        if let url = TextExpansionSnapshotStore.snapshotURL() {
            AppGroupDataProtection.protect(url)
        }
        if let url = TextExpansionUsageStore.usageURL() {
            AppGroupDataProtection.protect(url)
        }
        if let url = TextExpansionInbox.inboxURL() {
            AppGroupDataProtection.protect(url)
        }
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

    /// Checks if typing `text` completes a snippet trigger. If yes, deletes the trigger
    /// and expands it with the snippet body, appending the boundary character.
    private func checkForTriggerExpansion(insertingText text: String) -> Bool {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let combined = context + text

        guard let result = TextExpansionMatcher.expandStaticIfAvailable(
            in: combined,
            snippets: snippets,
            surface: .iOSKeyboard
        ) else {
            return false
        }

        // Haptic feedback for expansion!
        KeyboardHaptics.selectionPress()

        // Delete the trigger token backward
        let deleteCount = result.match.token.count
        for _ in 0..<deleteCount {
            textDocumentProxy.deleteBackward()
        }

        // Insert snippet body + boundary character (e.g. space or newline)
        let boundary = result.match.boundary.map(String.init) ?? ""
        let replacement = result.match.snippet.body + boundary
        textDocumentProxy.insertText(replacement)

        // Record the usage statistics in the shared App Group
        TextExpansionUsageStore.recordUse(snippetID: result.match.snippet.id)
        protectSharedAppGroupFiles()

        // Reset suggestions and reload snippets
        suggestions = []
        reloadSnippets()
        
        return true
    }

    /// Checks if typing `text` (a space/boundary character) completes a misspelled word.
    /// If yes, automatically replaces it with the best spelling correction.
    private func checkForAutocorrect(insertingText text: String) -> Bool {
        // Autocorrect only fires when inserting a single-character boundary (space, punctuation, return)
        guard text.count == 1, let char = text.first, TextExpansionMatcher.isBoundary(char) else {
            return false
        }

        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let lastWord = spellChecker.extractLastWord(from: context) else {
            return false
        }

        guard let correction = spellChecker.bestCorrection(for: lastWord) else {
            return false
        }

        let preservedCorrection = SpellCheckService.preserveCapitalization(original: lastWord, correction: correction)

        // Subtle key press feel for correction
        KeyboardHaptics.keyPress()

        // Delete the misspelled word backward
        for _ in 0..<lastWord.count {
            textDocumentProxy.deleteBackward()
        }

        // Insert corrected word + the boundary character
        textDocumentProxy.insertText(preservedCorrection + text)

        // Reset suggestions and update UI
        suggestions = []
        updateHostingView()

        return true
    }

    // MARK: - Hosting View

    private func updateHostingView() {
        let keyboardView = KeyboardView(
            snippets: snippets,
            suggestions: suggestions,
            onInsertText: { [weak self] text in
                guard let self else { return }
                // 1. First priority: trigger expansion
                if self.checkForTriggerExpansion(insertingText: text) {
                    return
                }
                // 2. Second priority: autocorrect on space/boundary
                if self.checkForAutocorrect(insertingText: text) {
                    return
                }
                // 3. Fallback: standard character insertion
                self.textDocumentProxy.insertText(text)
                self.refreshSuggestions()
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
                self?.protectSharedAppGroupFiles()
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
