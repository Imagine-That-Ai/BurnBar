import Foundation
import OpenBurnBarEngine
import OpenBurnBarComputerUseCore

extension ComputerUseRunCoordinator {
    // MARK: Concrete dispatch

    func dispatch(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        activeDriver: OpenBurnBarPlaywrightDriver?
    ) async throws -> BurnBarToolResult {
        try Task.checkCancellation()
        switch action {
        case .browser(let browser):
            guard let driver = activeDriver else { throw DispatchError.missingDriver }
            let response = try await dispatch(browser: browser, on: driver)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: response.ok,
                output: response.result,
                errorMessage: response.error,
                completedAt: Date()
            )
        case .macInput(let input):
            guard let dispatcher = macInputDispatcher else { throw DispatchError.missingDriver }
            let value = try await dispatcher(sessionId, input)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: true,
                output: value,
                completedAt: Date()
            )
        case .macInspect(let inspect):
            guard let dispatcher = macInspectDispatcher else { throw DispatchError.missingDriver }
            let value = try await dispatcher(sessionId, inspect)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: true,
                output: value,
                completedAt: Date()
            )
        case .phoneIntent:
            // Phone intents are translated to mac.input or browser
            // actions by the PhoneControlReceiver before reaching this
            // path. A raw phoneIntent here is a wiring bug.
            throw DispatchError.unsupportedTool("phone_intent_in_run_dispatch")
        case .remoteClipboard:
            // Remote clipboard is handled by the Mac app's phone-control
            // coordinator because it touches NSPasteboard and focused app
            // context. It must never route through the daemon run dispatcher.
            throw DispatchError.unsupportedTool("remote_clipboard_in_run_dispatch")
        }
    }

    struct ApprovalEvidence: Sendable, Equatable {
        var pngBase64: String
        var mimeType: String
        var sizeBytes: Int
        var hashHex: String
    }

    func approvalEvidence(
        for action: ComputerUseAction,
        activeDriver: OpenBurnBarPlaywrightDriver?
    ) async -> ApprovalEvidence? {
        guard case .browser = action,
              let activeDriver else {
            return nil
        }

        do {
            let response = try await activeDriver.screenshot()
            guard case .object(let object)? = response.result,
                  let base64 = object.stringValue(forKey: "base64"),
                  base64.isEmpty == false else {
                return nil
            }

            let decoded = Data(base64Encoded: base64)
            let sizeBytes = object.intValue(forKey: "sizeBytes") ?? decoded?.count ?? 0
            let hashHex = decoded.map(Self.sha256Hex(data:)) ?? Self.sha256Hex(string: base64)
            return ApprovalEvidence(
                pngBase64: base64,
                mimeType: "image/png",
                sizeBytes: sizeBytes,
                hashHex: hashHex
            )
        } catch {
            logger.warning("approval_screenshot_capture_failed", metadata: [
                "error": String(describing: error)
            ])
            return nil
        }
    }

    private static func sha256Hex(data: Data) -> String {
        PlatformCrypto.sha256Hex(data)
    }

    private static func sha256Hex(string: String) -> String {
        sha256Hex(data: Data(string.utf8))
    }

    private func dispatch(
        browser action: BrowserAction,
        on driver: OpenBurnBarPlaywrightDriver
    ) async throws -> OpenBurnBarPlaywrightDriver.Response {
        let response: OpenBurnBarPlaywrightDriver.Response
        switch action.kind {
        case .click:
            response = try await driver.click(
                selector: action.selector,
                positionX: action.positionX,
                positionY: action.positionY,
                timeoutMillis: action.timeoutMillis
            )
        case .fill:
            guard let selector = action.selector, let text = action.text else {
                throw DispatchError.invalidArguments("fill requires selector and text")
            }
            response = try await driver.fill(selector: selector, text: text, timeoutMillis: action.timeoutMillis)
        case .goto:
            guard let url = action.url else {
                throw DispatchError.invalidArguments("goto requires url")
            }
            // T-AI-04: validate the navigation target host AND its post-DNS
            // resolved IPs (anti-rebind) before navigating, so a hostname that
            // resolves to a loopback/private/metadata address is refused.
            let validatedURL = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                url,
                allowDataURL: true,
                resolver: browserHostResolver
            )
            response = try await driver.goto(url: validatedURL.absoluteString, timeoutMillis: action.timeoutMillis)
        case .key:
            guard let key = action.key else {
                throw DispatchError.invalidArguments("key requires key")
            }
            response = try await driver.key(key)
        case .select:
            guard let selector = action.selector, let value = action.value else {
                throw DispatchError.invalidArguments("select requires selector and value")
            }
            response = try await driver.select(selector: selector, value: value)
        case .screenshot:
            return try await driver.screenshot()
        case .extract:
            return try await driver.extract(selector: action.selector)
        }
        // T-AI-04: per-navigation / redirect / JS-nav re-validation. Each action's
        // own response carries the URL the page LANDED on (the bridge attaches
        // `finalURL` on goto and the live `url` on every interactive action), so a
        // server-side redirect or in-page JS navigation onto a blocked host is
        // refused WITHOUT an extra driver round trip. Re-checking from the
        // response (not a fresh `currentURL()` call) preserves the driver's
        // request accounting and adds no latency.
        try Self.enforceLandedURL(from: response, resolver: browserHostResolver)
        return response
    }

    /// T-AI-04 — re-validate the URL the page landed on, read from the action's
    /// own response (`finalURL` for navigation, `url` for interactive actions). A
    /// blocked landed host is refused so a redirect / JS-nav cannot steer the
    /// agent's browser onto the loopback/metadata plane. Absent fields are a
    /// no-op (the action did not navigate); http/https hosts are checked through
    /// the same literal + live DNS policy as initial navigation.
    static func enforceLandedURL(
        from response: OpenBurnBarPlaywrightDriver.Response,
        resolver: BurnBarBrowserHostResolver = OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
    ) throws {
        let landed = urlString(from: response.result, key: "finalURL")
            ?? urlString(from: response.result, key: "url")
        guard let landed else { return }
        try enforceLandedURLString(landed, resolver: resolver)
    }

    static func enforceLandedURLString(
        _ landed: String,
        resolver: BurnBarBrowserHostResolver = OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
    ) throws {
        let trimmed = landed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        // Pages legitimately sit on about:blank / data: between navigations;
        // those carry no host to rebind and are not range-checked.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("blob:") {
            return
        }
        guard let url = URL(string: trimmed), let host = url.host, host.isEmpty == false else {
            return
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        do {
            _ = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(trimmed, resolver: resolver)
        } catch {
            throw DispatchError.invalidArguments(
                "browser navigated to a blocked local, private, or metadata host: \(host) (\(error.localizedDescription))"
            )
        }
    }

    /// Extract a string URL field from a driver response result object.
    private static func urlString(from result: BurnBarJSONValue?, key: String) -> String? {
        guard case .object(let dict)? = result,
              case .string(let value)? = dict[key] else {
            return nil
        }
        return value
    }
}
