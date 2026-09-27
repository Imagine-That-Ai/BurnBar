import Foundation
import XCTest
@testable import OpenBurnBarKernel

/// Registry contract for the loopback services the app and daemon share:
/// unique default ports, loopback defaults, and host/port normalization. The
/// catalog-agreement test keeps `catalog.json` (data) pinned to the registry
/// so a drifted literal like the old MLX 8328↔8080 split cannot come back.
final class LocalServiceRegistryTests: XCTestCase {

    // MARK: - Descriptor shape

    func testDefaultPortsAreUniqueAcrossServices() {
        let ports = LocalService.allCases.map(\.descriptor.defaultPort)
        XCTAssertEqual(ports.count, Set(ports).count, "every local service needs its own default port")
    }

    func testEveryDefaultBaseURLIsLoopback() {
        for service in LocalService.allCases {
            let base = service.defaultBaseURL
            XCTAssertEqual(base.scheme, "http", "\(service) must default to plain http on loopback")
            XCTAssertEqual(base.host, "127.0.0.1", "\(service) default must be loopback")
            XCTAssertEqual(base.port, service.descriptor.defaultPort)
        }
    }

    func testRegistryStaticsPassTheirOwnInvariants() {
        XCTAssertTrue(LocalServiceInvariants.staticViolations().isEmpty)
    }

    func testOnlyBurnBarGatewayRequiresLoopback() {
        for service in LocalService.allCases {
            XCTAssertEqual(
                service.descriptor.loopbackRequired,
                service == .openBurnBarGateway,
                "\(service) loopback flag drifted",
            )
        }
    }

    // MARK: - baseURL(host:port:) normalization

    func testBaseURLNormalizesEmptyWildcardAndV6AnyHostToLoopback() {
        for host in [nil, "", "  ", "0.0.0.0", "::", "[::]"] {
            let url = LocalService.ollama.baseURL(host: host, port: 12345)
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:12345", "host \(host ?? "nil") should normalize to loopback")
        }
    }

    func testResolvedPortClampsInvalidToDefault() {
        let service = LocalService.hermesGateway
        XCTAssertEqual(service.resolvedPort(8642), 8642)
        XCTAssertEqual(service.resolvedPort(12345), 12345)
        for invalid in [0, -1, 65_536, .max] {
            XCTAssertEqual(service.resolvedPort(invalid), service.descriptor.defaultPort)
        }
    }

    func testResolvedHostMapsWildcardAndEmptyToLoopback() {
        let service = LocalService.openBurnBarGateway
        for wildcard in ["", "  ", "0.0.0.0", "::", "[::]", nil] {
            XCTAssertEqual(service.resolvedHost(wildcard), "127.0.0.1")
        }
        XCTAssertEqual(service.resolvedHost("192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(service.resolvedHost(" localhost "), "localhost")
    }

    func testAcceptedPortsContainsConfiguredPlusDefault() {
        let service = LocalService.openBurnBarGateway
        XCTAssertEqual(service.acceptedPorts(configured: 9999), [8317, 9999])
        XCTAssertEqual(service.acceptedPorts(configured: 8317), [8317])
        XCTAssertEqual(service.acceptedPorts(configured: 0), [8317])
    }

    func testBaseURLKeepsExplicitHost() {
        XCTAssertEqual(
            LocalService.hermesGateway.baseURL(host: "192.168.1.10", port: nil).absoluteString,
            "http://192.168.1.10:8642",
        )
    }

    func testBaseURLFallsBackToDefaultPortOnMissingOrInvalidPort() {
        XCTAssertEqual(
            LocalService.piAgentGateway.baseURL(host: nil, port: nil).absoluteString,
            "http://127.0.0.1:8765",
        )
        XCTAssertEqual(
            LocalService.piAgentGateway.baseURL(host: nil, port: 0).absoluteString,
            "http://127.0.0.1:8765",
        )
        XCTAssertEqual(
            LocalService.piAgentGateway.baseURL(host: nil, port: 70_000).absoluteString,
            "http://127.0.0.1:8765",
        )
    }

    // MARK: - matchesLoopbackEndpoint

    func testMatchesLoopbackEndpointMatchesBothHostsAndSchemes() {
        for text in [
            "http://127.0.0.1:8317",
            "https://localhost:8317/v1",
            "base_url = \"http://127.0.0.1:8317/v1/chat/completions\"",
            "points at 127.0.0.1:8317 bare"
        ] {
            XCTAssertTrue(LocalService.matchesLoopbackEndpoint(text, port: 8317), text)
        }
        XCTAssertFalse(LocalService.matchesLoopbackEndpoint("http://127.0.0.1:8318", port: 8317))
        XCTAssertFalse(LocalService.matchesLoopbackEndpoint("http://192.168.1.5:8317", port: 8317))
        XCTAssertFalse(LocalService.matchesLoopbackEndpoint("port 8317 without host", port: 8317))
    }

    // MARK: - matchesLoopbackHTTPEndpoint

    func testMatchesLoopbackHTTPEndpointRequiresScheme() {
        for text in [
            "http://127.0.0.1:8317",
            "https://localhost:8317/v1",
            "url = \"http://127.0.0.1:8317/v1/chat/completions\""
        ] {
            XCTAssertTrue(LocalService.matchesLoopbackHTTPEndpoint(text, port: 8317), text)
        }
        for text in [
            // Bare host:port mentions — comments, notes, unrelated keys — must
            // not count as pointing at the service.
            "127.0.0.1:8317",
            "# the gateway used to be at 127.0.0.1:8317",
            "notes = \"reachable on localhost:8317\"",
            "ws://127.0.0.1:8317",
            "http://127.0.0.1:8318",
            "http://192.168.1.5:8317"
        ] {
            XCTAssertFalse(LocalService.matchesLoopbackHTTPEndpoint(text, port: 8317), text)
        }
    }

    // MARK: - configurationViolations

    func testConfigurationViolationsFlagPortCollisions() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .hermesGateway: "http://127.0.0.1:8765"
        ])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.kind, .endpointCollision)
        XCTAssertEqual(violations.first?.severity, .configuration)
        XCTAssertEqual(
            Set(violations.first?.services ?? []),
            [.hermesGateway, .piAgentGateway],
        )
        XCTAssertEqual(violations.first?.endpoint, "127.0.0.1:8765")
    }

    func testConfigurationViolationsFlagUnparseableOverrides() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .ollama: "not a url at all"
        ])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.kind, .unparseableEndpoint)
        XCTAssertEqual(violations.first?.endpoint, "not a url at all")
    }

    func testConfigurationViolationsFlagNonLoopbackGateway() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .openBurnBarGateway: "http://192.168.1.20:8317"
        ])
        XCTAssertTrue(violations.contains {
            $0.kind == .gatewayNotLoopback && $0.services == [.openBurnBarGateway]
        })
    }

    /// Two BurnBar-managed services on the same host:port always report —
    /// BurnBar owns both endpoints, so one of them is a real misconfig.
    func testCollisionBetweenManagedServicesAlwaysReports() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .piAgentGateway: "http://127.0.0.1:8642"
        ])
        XCTAssertTrue(violations.contains {
            $0.kind == .endpointCollision
                && Set($0.services) == [.hermesGateway, .piAgentGateway]
        })
    }

    /// The false positive this rule exists for: a user who pointed Hermes at
    /// 127.0.0.1:8080 because they never run MLX must not be warned forever
    /// about colliding with MLX's unused default.
    func testCollisionWithExternalAtDefaultIsNotReported() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .hermesGateway: "http://127.0.0.1:8080"
        ])
        XCTAssertFalse(violations.contains { $0.kind == .endpointCollision })
    }

    /// …but when the user explicitly moved the external service onto a
    /// BurnBar service's port, the collision is real and reports.
    func testCollisionWithExplicitlyConfiguredExternalReports() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .mlxServer: "http://127.0.0.1:8642"
        ])
        XCTAssertTrue(violations.contains {
            $0.kind == .endpointCollision
                && Set($0.services) == [.hermesGateway, .mlxServer]
        })
    }

    /// An external override equal to its own registry default is not an
    /// override — the stored value changes nothing, so it cannot turn a
    /// managed-service move into a warning.
    func testExternalConfiguredToItsDefaultStillSuppressesCollision() {
        let violations = LocalServiceInvariants.configurationViolations(resolved: [
            .ollama: "http://127.0.0.1:11434",
            .hermesGateway: "http://127.0.0.1:11434"
        ])
        XCTAssertFalse(violations.contains { $0.kind == .endpointCollision })
    }

    func testConfigurationViolationsAreCleanForDefaults() {
        XCTAssertTrue(LocalServiceInvariants.configurationViolations(resolved: [:]).isEmpty)
    }

    // MARK: - catalog.json agreement

    /// Every catalog provider whose baseURL points at loopback must carry a
    /// registry-owned port — the mlx 8328↔8080 split is exactly the drift this
    /// pins. (Loopback URL is the real signal; some local providers like `mlx`
    /// don't set the catalog's `local` flag.)
    func testCatalogLoopbackBaseURLsMatchRegistry() throws {
        let catalog = try BurnBarCatalogLoader.loadBundledCatalog()
        var checked = 0
        for provider in catalog.providers {
            guard let components = URLComponents(string: provider.baseURL),
                  let host = components.host,
                  ["127.0.0.1", "localhost"].contains(host),
                  let port = components.port else { continue }
            let service = LocalService.allCases.first { $0.descriptor.defaultPort == port }
            XCTAssertNotNil(
                service,
                "provider \(provider.id) uses loopback port \(port) that no registered local service owns",
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "expected at least one loopback local catalog provider")
    }
}
