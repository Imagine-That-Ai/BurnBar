import AppKit
import Darwin
import Foundation

struct TrayArgs {
    var port: Int = 8320
    var parentPid: Int32 = 0
    var nodePath: String?
    var cliPath: String?
    var token: String = "local-cliproxy"

    static func parse(_ argv: [String]) -> TrayArgs {
        var args = TrayArgs()
        if let envToken = ProcessInfo.processInfo.environment["OPENBURNBAR_GATEWAY_TOKEN"] ?? ProcessInfo.processInfo.environment["OPENBURNBAR_TOKEN"], !envToken.isEmpty {
            args.token = envToken
        }
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            let next = index + 1 < argv.count ? argv[index + 1] : nil
            switch arg {
            case "--port":
                if let next, let port = Int(next) { args.port = port }
                index += 2
            case "--parent-pid":
                if let next, let pid = Int32(next) { args.parentPid = pid }
                index += 2
            case "--node":
                args.nodePath = next
                index += 2
            case "--cli":
                args.cliPath = next
                index += 2
            case "--token":
                if let next { args.token = next }
                index += 2
            default:
                index += 1
            }
        }
        return args
    }
}

struct Snippet: Decodable, Equatable {
    let id: String
    let title: String
    let body: String
    let caveat: String
}

struct PanelPayload: Decodable {
    let product: String
    let listening: Bool
    let ready: String
    let port: Int
    let openaiUrl: String
    let anthropicUrl: String
    let localKey: String
    let mode: String?
    let provider: String?
    let configured: Bool
    let models: [String]
    let snippets: [Snippet]
    let podexTitle: String
    let podexBody: String
    let installBurnBar: String
    let openBurnBar: String
    let commands: Commands

    struct Commands: Decodable {
        let status: String
        let stop: String
    }
}

struct HealthPayload: Decodable {
    let status: String
    let pid: Int
    let port: Int
    let mode: String?
    let provider: String?
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

enum TrayClientError: Error {
    case redirect
    case badStatus
}

func isLoopbackHTTP(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "http",
          url.host == "127.0.0.1" else {
        return false
    }
    return true
}

func containsUnsafeURL(_ text: String) -> Bool {
    if text.lowercased().contains("localhost") {
        return true
    }
    let pattern = #"https?://[^\s"'`<>]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return true
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in regex.matches(in: text, options: [], range: range) {
        guard let matchRange = Range(match.range, in: text) else {
            return true
        }
        if !isLoopbackHTTP(String(text[matchRange])) {
            return true
        }
    }
    return false
}

final class GatewayClient {
    let port: Int
    let token: String
    private let session: URLSession
    private let redirects = RejectRedirects()

    init(port: Int, token: String) {
        self.port = port
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func get<T: Decodable>(_ path: String, authed: Bool, as type: T.Type) async throws -> T {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if authed {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if (300 ..< 400).contains(http.statusCode) {
            throw TrayClientError.redirect
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TrayClientError.badStatus
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

final class GatewayPanelController: NSViewController {
    let args: TrayArgs
    let client: GatewayClient
    private var pollTimer: Timer?
    private var snippets: [Snippet] = []
    private var selectedSnippet = 0
    private var lastAction = "Ready."

    private let statusLabel = NSTextField(labelWithString: "Down")
    private let modeLabel = NSTextField(labelWithString: "—")
    private let modelsLabel = NSTextField(wrappingLabelWithString: "Models: —")
    private let openaiField = NSTextField(string: "")
    private let anthropicField = NSTextField(string: "")
    private let keyField = NSTextField(string: "local-cliproxy")
    private let commandsLabel = NSTextField(wrappingLabelWithString: "")
    private let snippetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let snippetView = NSTextView()
    private let caveatLabel = NSTextField(wrappingLabelWithString: "")
    private let actionLabel = NSTextField(wrappingLabelWithString: "Ready.")

    init(args: TrayArgs) {
        self.args = args
        self.client = GatewayClient(port: args.port, token: args.token)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 580))
        view = root

        statusLabel.font = NSFont.boldSystemFont(ofSize: 16)
        statusLabel.setAccessibilityLabel("Gateway status")
        modeLabel.setAccessibilityLabel("Gateway mode")
        modelsLabel.setAccessibilityLabel("Advertised models")
        openaiField.isEditable = false
        openaiField.isBezeled = true
        openaiField.setAccessibilityLabel("OpenAI base URL")
        anthropicField.isEditable = false
        anthropicField.isBezeled = true
        anthropicField.setAccessibilityLabel("Anthropic origin URL")
        keyField.isEditable = false
        keyField.isBezeled = true
        keyField.setAccessibilityLabel("Loopback local key")
        commandsLabel.setAccessibilityLabel("Status and stop commands")
        snippetPopup.setAccessibilityLabel("Client snippet")
        snippetPopup.target = self
        snippetPopup.action = #selector(snippetChanged)
        snippetView.isEditable = false
        snippetView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        snippetView.textContainerInset = NSSize(width: 6, height: 6)
        caveatLabel.font = NSFont.systemFont(ofSize: 11)
        caveatLabel.textColor = .secondaryLabelColor
        caveatLabel.setAccessibilityLabel("Snippet caveat")
        let snippetScroll = NSScrollView()
        snippetScroll.hasVerticalScroller = true
        snippetScroll.documentView = snippetView
        snippetScroll.borderType = .bezelBorder
        snippetScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let stack: NSStackView = NSStackView(views: [
            labeledRow("Status", statusLabel),
            modeLabel,
            modelsLabel,
            labeledRow("OpenAI URL", openaiField),
            labeledRow("Anthropic URL", anthropicField),
            labeledRow("local-cliproxy", keyField),
            commandsLabel,
            buttonRow([
                ("Copy OpenAI URL", #selector(copyOpenAI)),
                ("Copy Anthropic URL", #selector(copyAnthropic)),
                ("Copy local key", #selector(copyKey)),
            ]),
            snippetPopup,
            snippetScroll,
            caveatLabel,
            buttonRow([("Copy snippet", #selector(copySnippet))]),
            buttonRow([
                ("Install BurnBar", #selector(installBurnBar)),
                ("Open BurnBar", #selector(openBurnBar)),
            ]),
            buttonRow([
                ("Install Podex", #selector(installPodex)),
                ("Stop gateway", #selector(stopGateway)),
            ]),
            actionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])

        openaiField.stringValue = "http://127.0.0.1:\(args.port)/v1"
        anthropicField.stringValue = "http://127.0.0.1:\(args.port)"
        commandsLabel.stringValue = "openburnbar proxy status --port \(args.port)\nopenburnbar proxy stop --port \(args.port)"
        actionLabel.stringValue = lastAction
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func labeledRow(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11)
        let row = NSStackView(views: [label, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func buttonRow(_ items: [(String, Selector)]) -> NSStackView {
        let buttons = items.map { title, selector -> NSButton in
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(title)
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let panel = try await self.client.get("/v1/gateway/panel", authed: true, as: PanelPayload.self)
                await MainActor.run {
                    self.apply(panel: panel)
                }
            } catch {
                let health = try? await self.client.get("/health", authed: false, as: HealthPayload.self)
                await MainActor.run {
                    self.statusLabel.stringValue = health == nil ? "Down" : "Degraded"
                    self.modeLabel.stringValue = health.map { "\($0.mode ?? "standalone") \($0.provider ?? "")" } ?? "gateway not reachable"
                }
            }
        }
    }

    private func apply(panel: PanelPayload) {
        statusLabel.stringValue = panel.ready.capitalized
        let provider = panel.provider ?? "none"
        modeLabel.stringValue = "\(panel.mode ?? "standalone") · \(provider) · \(panel.configured ? "configured" : "unconfigured")"
        modelsLabel.stringValue = "Models: " + (panel.models.isEmpty ? "—" : panel.models.joined(separator: ", "))
        if isLoopbackHTTP(panel.openaiUrl) {
            openaiField.stringValue = panel.openaiUrl
        }
        if isLoopbackHTTP(panel.anthropicUrl) {
            anthropicField.stringValue = panel.anthropicUrl
        }
        keyField.stringValue = panel.localKey
        commandsLabel.stringValue = "\(panel.commands.status)\n\(panel.commands.stop)"
        let safeSnippets = panel.snippets.filter { !containsUnsafeURL($0.body) }
        if safeSnippets != snippets {
            snippets = safeSnippets
            rebuildSnippetMenu()
        }
    }

    private func rebuildSnippetMenu() {
        let previous = snippetPopup.titleOfSelectedItem
        snippetPopup.removeAllItems()
        for snippet in snippets {
            snippetPopup.addItem(withTitle: snippet.title)
        }
        if let previous, snippetPopup.itemTitles.contains(previous) {
            snippetPopup.selectItem(withTitle: previous)
        } else if !snippets.isEmpty {
            snippetPopup.selectItem(at: 0)
        }
        snippetChanged()
    }

    @objc private func snippetChanged() {
        selectedSnippet = max(0, snippetPopup.indexOfSelectedItem)
        guard snippets.indices.contains(selectedSnippet) else {
            snippetView.string = ""
            caveatLabel.stringValue = ""
            return
        }
        let snippet = snippets[selectedSnippet]
        snippetView.string = snippet.body
        caveatLabel.stringValue = snippet.caveat
    }

    private func copy(_ value: String, label: String) {
        guard !containsUnsafeURL(value) else {
            actionLabel.stringValue = "Refusing to copy a non-loopback value."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        actionLabel.stringValue = "Copied \(label)."
    }

    @objc private func copyOpenAI() { copy(openaiField.stringValue, label: "OpenAI URL") }
    @objc private func copyAnthropic() { copy(anthropicField.stringValue, label: "Anthropic URL") }
    @objc private func copyKey() { copy(keyField.stringValue, label: "local key") }
    @objc private func copySnippet() {
        guard snippets.indices.contains(selectedSnippet) else { return }
        copy(snippets[selectedSnippet].body, label: "snippet")
    }

    @objc private func installBurnBar() {
        actionLabel.stringValue = "Installing OpenBurnBar…"
        let process = Process()
        if let node = args.nodePath, let cli = args.cliPath {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [cli, "app", "install"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openburnbar", "app", "install"]
        }
        run(process, empty: "openburnbar app install finished with no output.")
    }

    @objc private func openBurnBar() {
        actionLabel.stringValue = "Opening OpenBurnBar…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "OpenBurnBar"]
        run(process, empty: "Opened OpenBurnBar.")
    }

    @objc private func installPodex() {
        let alert = NSAlert()
        alert.messageText = "Podex — coming soon"
        alert.informativeText = """
        Podex is not available to install yet.

        There is no download URL, no installer, and no feed in this release. When a first-party Podex feed exists, it will follow the same explicit pattern as openburnbar app install.

        Until then, use OpenBurnBar for burn/quota and this gateway for local loopback relay.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        actionLabel.stringValue = "Podex is coming soon — no download was started."
    }

    @objc private func stopGateway() {
        guard args.parentPid > 1 else {
            actionLabel.stringValue = "Refusing to stop: missing parent proxy PID."
            return
        }
        actionLabel.stringValue = "Stopping gateway…"
        let process = Process()
        if let node = args.nodePath, let cli = args.cliPath {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [cli, "proxy", "stop", "--port", String(args.port)]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openburnbar", "proxy", "stop", "--port", String(args.port)]
        }
        run(process, empty: "Gateway stop requested.")
    }

    private func run(_ process: Process, empty: String) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let text = String(data: output, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last { !$0.isEmpty }
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self?.actionLabel.stringValue = text ?? empty
                } else {
                    self?.actionLabel.stringValue = text ?? "Command failed (exit \(proc.terminationStatus))."
                }
            }
        }
        do {
            try process.run()
        } catch {
            actionLabel.stringValue = error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let shared = AppDelegate()
    let args = TrayArgs.parse(CommandLine.arguments)
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var panel: GatewayPanelController?
    var parentWatch: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "point.3.connected.trianglepath",
                accessibilityDescription: "OpenBurnBar Gateway"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "OpenBurnBar Gateway"
            button.setAccessibilityTitle("OpenBurnBar Gateway")
            button.setAccessibilityLabel("OpenBurnBar Gateway")
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem.autosaveName = NSStatusItem.AutosaveName("ai.imaginethat.openburnbar.gateway-tray")

        let panel = GatewayPanelController(args: args)
        self.panel = panel
        popover.contentViewController = panel
        popover.contentSize = NSSize(width: 380, height: 580)
        popover.behavior = .transient
        popover.delegate = self
        watchParent()
    }

    private func watchParent() {
        guard args.parentPid > 1 else { return }
        parentWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if kill(self.args.parentPid, 0) != 0 {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
enum OpenBurnBarGatewayTray {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = AppDelegate.shared
        app.run()
    }
}
