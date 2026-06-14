import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// T-AI-04: per-navigation re-validation + resolved-IP (post-DNS) anti-rebind in
/// the daemon browser driver. A literal private/metadata host is already blocked;
/// these tests prove a hostname that RESOLVES to a private/link-local/metadata IP
/// is also refused, so DNS rebinding cannot steer the agent's browser onto the
/// loopback/metadata plane.
final class BurnBarBrowserAntiRebindTests: XCTestCase {
    func test_resolvedURL_rejectsHostResolvingToMetadataIP() {
        // Classic SSRF rebind: a public-looking host resolves to 169.254.169.254.
        let resolver: (String) -> [String] = { _ in ["169.254.169.254"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://evil.example.com/", resolver: resolver
            )
        )
    }

    func test_resolvedURL_rejectsHostResolvingToLoopback() {
        let resolver: (String) -> [String] = { _ in ["127.0.0.1"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://evil.example.com/", resolver: resolver
            )
        )
    }

    func test_resolvedURL_rejectsHostResolvingToPrivateRange() {
        let resolver: (String) -> [String] = { _ in ["10.0.0.5"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://internal.example.com/", resolver: resolver
            )
        )
        let ula: (String) -> [String] = { _ in ["fd00::1"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://internal.example.com/", resolver: ula
            )
        )
    }

    func test_resolvedURL_rejectsWhenAnyResolvedAddressIsBlocked() {
        // Mixed answer (a public IP and a private IP) must still fail closed.
        let resolver: (String) -> [String] = { _ in ["93.184.216.34", "192.168.1.10"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://example.com/", resolver: resolver
            )
        )
    }

    func test_resolvedURL_rejectsWhenResolutionFails() {
        let resolver: (String) -> [String] = { _ in [] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://example.com/", resolver: resolver
            )
        )
    }

    func test_resolvedURL_acceptsHostResolvingToPublicIP() {
        let resolver: (String) -> [String] = { _ in ["93.184.216.34"] }
        XCTAssertNoThrow(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://example.com/", resolver: resolver
            )
        )
    }

    func test_resolvedURL_literalPublicIPShortCircuitsResolver() {
        // A literal IP is already range-checked by validatedURL; the resolver must
        // not be consulted (and certainly must not be required).
        var resolverCalled = false
        let resolver: (String) -> [String] = { _ in resolverCalled = true; return [] }
        XCTAssertNoThrow(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "https://93.184.216.34/", resolver: resolver
            )
        )
        XCTAssertFalse(resolverCalled, "literal IP must not trigger DNS resolution")
    }

    func test_resolvedURL_stillRejectsLiteralBlockedHostBeforeResolving() {
        // The literal-host gate runs first, so a literal metadata host fails even
        // with a resolver that would (wrongly) say public.
        let resolver: (String) -> [String] = { _ in ["93.184.216.34"] }
        XCTAssertThrowsError(
            try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                "http://169.254.169.254/latest/meta-data/", resolver: resolver
            )
        )
    }

    func test_isBlockedHost_catchesRedirectLandingHosts() {
        // The per-navigation landed-URL re-check (enforceLandedURLString) is built
        // on isBlockedHost; prove the host judgments a redirect could land on.
        XCTAssertTrue(OpenBurnBarBrowserTargetPolicy.isBlockedHost("localhost"))
        XCTAssertTrue(OpenBurnBarBrowserTargetPolicy.isBlockedHost("169.254.169.254"))
        XCTAssertTrue(OpenBurnBarBrowserTargetPolicy.isBlockedHost("metadata.google.internal"))
        XCTAssertTrue(OpenBurnBarBrowserTargetPolicy.isBlockedHost("10.1.2.3"))
        XCTAssertFalse(OpenBurnBarBrowserTargetPolicy.isBlockedHost("example.com"))
    }

    // MARK: - Per-navigation / redirect / JS-nav landed-URL re-validation

    private func driverResponse(result: BurnBarJSONValue?) -> OpenBurnBarPlaywrightDriver.Response {
        OpenBurnBarPlaywrightDriver.Response(id: 1, ok: true, result: result, error: nil, elapsedMillis: 1)
    }

    func test_enforceLandedURL_refusesRedirectToBlockedFinalURL() {
        // goto returned 2xx but the page redirected onto the metadata plane.
        let response = driverResponse(result: .object([
            "kind": .string("goto"),
            "url": .string("https://example.com/"),
            "finalURL": .string("http://169.254.169.254/latest/meta-data/")
        ]))
        XCTAssertThrowsError(try ComputerUseRunCoordinator.enforceLandedURL(from: response))
    }

    func test_enforceLandedURL_refusesJSNavToBlockedHostAfterClick() {
        // A click triggered location = 'http://localhost:...'; the bridge reports
        // the landed URL under finalURL.
        let response = driverResponse(result: .object([
            "kind": .string("click"),
            "selector": .string("#go"),
            "finalURL": .string("http://localhost:9000/admin")
        ]))
        XCTAssertThrowsError(try ComputerUseRunCoordinator.enforceLandedURL(from: response))
    }

    func test_enforceLandedURL_allowsPublicLandedURL() {
        let response = driverResponse(result: .object([
            "kind": .string("goto"),
            "finalURL": .string("https://example.com/welcome")
        ]))
        XCTAssertNoThrow(try ComputerUseRunCoordinator.enforceLandedURL(from: response))
    }

    func test_enforceLandedURL_isNoOpWhenNoURLField() {
        // Non-navigating responses (e.g. the echo fixture) carry no URL → no-op.
        let response = driverResponse(result: .object([
            "method": .string("click"),
            "params": .object([:])
        ]))
        XCTAssertNoThrow(try ComputerUseRunCoordinator.enforceLandedURL(from: response))
    }

    func test_enforceLandedURL_allowsAboutBlankAndDataURLs() {
        for landed in ["about:blank", "data:text/html,<p>x</p>", "blob:https://example.com/abc"] {
            XCTAssertNoThrow(try ComputerUseRunCoordinator.enforceLandedURLString(landed), "\(landed) must pass")
        }
    }
}
