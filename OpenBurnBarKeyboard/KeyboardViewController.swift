import UIKit
import SwiftUI
import OpenBurnBarCore

/// The principal input view controller for the custom iOS keyboard extension.
///
/// Hosts the gorgeous SwiftUI `KeyboardView` inside a `UIHostingController` and
/// wires up system keyboard operations (text input, deleting backward, next keyboard)
/// and data actions (saving keyboard composer snippets, tracking usage frequencies).
final class KeyboardViewController: UIInputViewController {
    private var snippets: [TextExpansionSnippet] = []
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        reloadSnippets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSnippets()
    }

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

    private func updateHostingView() {
        let keyboardView = KeyboardView(
            snippets: snippets,
            onInsertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onAdvanceToNextInputMode: { [weak self] in
                self?.advanceToNextInputMode()
            },
            onSnippetUsed: { [weak self] snippet in
                TextExpansionUsageStore.recordUse(snippetID: snippet.id)
                self?.reloadSnippets()
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
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: view.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: 242)
            ])
            hc.didMove(toParent: self)
            hostingController = hc
        }
    }
}
