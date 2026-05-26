import UIKit
import OpenBurnBarCore

final class KeyboardViewController: UIInputViewController {
    private var snippets: [TextExpansionSnippet] = []
    private let rows: [[String]] = [
        Array("qwertyuiop").map(String.init),
        Array("asdfghjkl").map(String.init),
        ["&&"] + Array("zxcvbnm").map(String.init) + ["delete"],
        ["next", "space", ".", ",", "return"]
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        buildKeyboard()
        reloadSnippets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSnippets()
    }

    private func buildKeyboard() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        root.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        root.isLayoutMarginsRelativeArrangement = true

        for row in rows {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 5
            for key in row {
                stack.addArrangedSubview(makeKeyButton(title: displayTitle(for: key), key: key))
            }
            root.addArrangedSubview(stack)
        }

        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 238)
        ])
    }

    private func makeKeyButton(title: String, key: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = key == "space" ? .secondarySystemBackground : .tertiarySystemBackground
        configuration.baseForegroundColor = .label

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.accessibilityLabel = accessibilityLabel(for: key)
        button.addAction(UIAction { [weak self] _ in
            self?.handleKey(key)
        }, for: .touchUpInside)
        return button
    }

    private func displayTitle(for key: String) -> String {
        switch key {
        case "delete": return "Delete"
        case "space": return "Space"
        case "return": return "Return"
        case "next": return "Next"
        default: return key
        }
    }

    private func accessibilityLabel(for key: String) -> String {
        switch key {
        case "&&": return "Text expansion prefix"
        case "delete": return "Delete"
        case "space": return "Space"
        case "return": return "Return"
        case "next": return "Next keyboard"
        default: return key
        }
    }

    private func handleKey(_ key: String) {
        switch key {
        case "delete":
            textDocumentProxy.deleteBackward()
        case "space":
            textDocumentProxy.insertText(" ")
            applyTextExpansionIfAvailable()
        case "return":
            textDocumentProxy.insertText("\n")
            applyTextExpansionIfAvailable()
        case "next":
            advanceToNextInputMode()
        default:
            textDocumentProxy.insertText(key)
            applyTextExpansionIfAvailable()
        }
    }

    private func applyTextExpansionIfAvailable() {
        guard let context = textDocumentProxy.documentContextBeforeInput,
              let match = TextExpansionMatcher.match(
                in: context,
                snippets: snippets,
                surface: .iOSKeyboard,
                expandWhenUnambiguous: true
              ),
              match.requiresPreview == false else {
            return
        }

        let boundary = match.boundary.map(String.init) ?? ""
        let deleteCount = match.token.count + boundary.count
        for _ in 0..<deleteCount {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(match.snippet.body + boundary)
    }

    private func reloadSnippets() {
        guard let url = TextExpansionSnapshotStore.snapshotURL(),
              let snapshot = try? TextExpansionSnapshotStore.read(from: url) else {
            snippets = []
            return
        }
        snippets = snapshot.snippets.filter { snippet in
            snippet.mode == .staticText
                && snippet.scope.allows(surface: .iOSKeyboard)
        }
    }
}
