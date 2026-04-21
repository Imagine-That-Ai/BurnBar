import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarHTTPGatewayServerTests: XCTestCase {
    func testGatewayConfigurationValidationRejectsUnsafeHosts() {
        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "0.0.0.0", port: 8317, authToken: nil).validationError,
            "Gateway wildcard bind addresses are not allowed. Use a specific interface address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "bad host", port: 8317, authToken: nil).validationError,
            "Gateway host 'bad host' is not a valid hostname or IP address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "192.168.0.10", port: 8317, authToken: nil).validationError,
            "A non-loopback gateway bind address requires an auth token for security."
        )
    }

    func testGatewayReturns400ForInvalidCompletionPayload() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data("{\"model\":}".utf8)
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("invalid JSON request body"))
    }

    func testGatewayReturns413ForOversizedBody() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let oversizedRequest = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: 1048577\r\n"
            + "\r\n"
        let (status, _, _) = try sendRawGatewayRequest(
            port: harness.port,
            request: oversizedRequest
        )
        XCTAssertEqual(status, 413)
    }

    func testGatewayCORSAllowsLoopbackOriginsOnly() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (allowedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Origin": "http://localhost:3000"]
        )
        XCTAssertEqual(allowedResponse.statusCode, 200)
        XCTAssertEqual(allowedResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "http://localhost:3000")

        let (blockedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Origin": "https://evil.example.com"]
        )
        XCTAssertEqual(blockedResponse.statusCode, 200)
        XCTAssertNil(blockedResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        let (preflightResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "OPTIONS",
            path: "/v1/chat/completions",
            headers: [
                "Origin": "http://127.0.0.1:5173",
                "Access-Control-Request-Method": "POST"
            ]
        )
        XCTAssertEqual(preflightResponse.statusCode, 204)
        XCTAssertEqual(preflightResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "http://127.0.0.1:5173")
    }

    func testGatewayAuthRequiresBearerTokenWhenConfigured() async throws {
        let harness = try GatewayHarness(authToken: "gateway-secret")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (missingAuthResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health"
        )
        XCTAssertEqual(missingAuthResponse.statusCode, 401)

        let (invalidAuthResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer wrong"]
        )
        XCTAssertEqual(invalidAuthResponse.statusCode, 401)

        let (authorizedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer gateway-secret"]
        )
        XCTAssertEqual(authorizedResponse.statusCode, 200)
    }

    private func sendGatewayRequest(
        port: Int,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (httpResponse, responseData)
    }

    private func sendRawGatewayRequest(
        port: Int,
        request: String
    ) throws -> (status: Int, headers: [String: String], body: String) {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = 0x0100007F

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        guard let requestData = request.data(using: .utf8) else {
            throw POSIXError(.EILSEQ)
        }
        try requestData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let wrote = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard wrote > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= wrote
                offset += wrote
            }
        }

        shutdown(fileDescriptor, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                break
            }
            responseData.append(contentsOf: buffer.prefix(bytesRead))
        }

        let responseText = String(decoding: responseData, as: UTF8.self)
        let sections = responseText.components(separatedBy: "\r\n\r\n")
        let headerSection = sections.first ?? ""
        let body = sections.dropFirst().joined(separator: "\r\n\r\n")
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw POSIXError(.EBADMSG)
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw POSIXError(.EBADMSG)
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return (status: status, headers: headers, body: body)
    }
}

private final class GatewayHarness {
    let port: Int
    private let server: BurnBarHTTPGatewayServer

    init(authToken: String? = nil) throws {
        self.port = try Self.reservePort()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )

        self.server = BurnBarHTTPGatewayServer(
            configuration: BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "127.0.0.1",
                port: port,
                authToken: authToken
            ),
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
    }

    func start() async throws {
        try await server.start()
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func stop() async {
        await server.stop()
    }

    private static func reservePort() throws -> Int {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = 0x0100007F

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(socketFD, rebound, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}
