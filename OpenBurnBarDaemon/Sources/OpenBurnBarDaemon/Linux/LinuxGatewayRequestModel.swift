#if os(Linux)
// cov:ignore-start -- reason: Linux-only gateway paths are exercised by the Linux gateway suite, not macOS package coverage.
import Foundation
import Glibc
import OpenBurnBarEngine
import OpenBurnBarKernel

enum LinuxGatewayResponse {
    case buffered(Data)
    case streamed
}

struct LinuxGatewayStreamPlan {
    let usageFormat: GatewayStreamUsageFormat
    let open: (BurnBarModelVariant?) async throws -> BurnBarProviderProxyStream
}

final class LinuxGatewayStreamCommit {
    var responseStarted = false
}

enum LinuxGatewayEndpoint: Equatable {
    case chatCompletions
    case responses
    case anthropicMessages

    var requestPath: String {
        switch self {
        case .chatCompletions:
            return "/v1/chat/completions"
        case .responses:
            return "/v1/responses"
        case .anthropicMessages:
            return "/v1/messages"
        }
    }

    var displayName: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses"
        case .anthropicMessages:
            return "Anthropic Messages"
        }
    }
}

struct LinuxGatewayModelRequest: Decodable {
    let model: String?
    let stream: Bool?
}

struct LinuxGatewayCatalogModel: Sendable {
    let id: String
    let displayName: String
    let providerID: String
    let providerName: String
    let baseModelID: String?
    let accountIDs: [String]
    let formatFamily: BurnBarProviderFormatFamily
    let isEnabled: Bool
    let routeEligible: Bool
    let advertisementEnabled: Bool
    let isAlias: Bool
    let isVariant: Bool
}

struct LinuxModelCatalogCache {
    let configurationHash: Int
    let storedAt: Date
    let models: [LinuxGatewayCatalogModel]
}

struct LinuxHTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var headers: [String: String] = [:]
    var body = Data()
}

func readHTTPRequest(
    from fileDescriptor: Int32,
    maxBytes: Int = BurnBarHTTPGatewayServer.maxRequestBytes,
    maxHeaderBytes: Int = 16 * 1024
) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var expectedTotalBytes: Int?
    while true {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 {
            guard let expectedTotalBytes else {
                throw BurnBarHTTPGatewayError.malformedRequest("request headers are incomplete")
            }
            guard data.count >= expectedTotalBytes else {
                throw BurnBarHTTPGatewayError.incompleteRequest
            }
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw BurnBarHTTPGatewayError.incompleteRequest
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > maxBytes {
            throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxBytes)
        }
        if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
            guard headerEnd.upperBound <= maxHeaderBytes else {
                throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxHeaderBytes)
            }
            let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = try parsedContentLength(from: head)
            let bodyStart = headerEnd.upperBound
            guard bodyStart <= maxBytes, contentLength <= maxBytes - bodyStart else {
                throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxBytes)
            }
            let expected = bodyStart + contentLength
            expectedTotalBytes = expected
            if data.count == expected {
                break
            }
            if data.count > expected {
                throw BurnBarHTTPGatewayError.malformedRequest("multiple HTTP frames are not supported")
            }
        }
    }
    return data
}

func parsedContentLength(from head: String) throws -> Int {
    let lines = head.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
        throw BurnBarHTTPGatewayError.malformedRequest("request line is missing")
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3,
          requestParts[0].isEmpty == false,
          requestParts[1].hasPrefix("/"),
          requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
        throw BurnBarHTTPGatewayError.malformedRequest("invalid request line")
    }

    var contentLength: Int?
    for line in lines.dropFirst() {
        guard !line.isEmpty else { continue }
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header line")
        }
        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header name")
        }
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "transfer-encoding" {
            throw BurnBarHTTPGatewayError.unsupportedTransferEncoding(value)
        }
        if name == "content-length" {
            guard !value.isEmpty, value.allSatisfy({ $0.isNumber }), let parsed = Int(value), parsed >= 0 else {
                throw BurnBarHTTPGatewayError.malformedRequest("invalid content length")
            }
            if let contentLength, contentLength != parsed {
                throw BurnBarHTTPGatewayError.malformedRequest("conflicting content lengths")
            }
            contentLength = parsed
        }
    }
    return contentLength ?? 0
}

func parseRequest(_ data: Data) throws -> LinuxHTTPRequest {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
        throw BurnBarHTTPGatewayError.malformedRequest("request headers are incomplete")
    }
    let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    _ = try parsedContentLength(from: head)
    var lines = head.components(separatedBy: "\r\n")
    let start = lines.isEmpty ? "" : lines.removeFirst()
    let startParts = start.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var request = LinuxHTTPRequest()
    guard startParts.count == 3 else {
        throw BurnBarHTTPGatewayError.malformedRequest("invalid request line")
    }
    request.method = startParts[0].uppercased()
    request.path = startParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header line")
        }
        request.headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    request.body = data[headerEnd.upperBound...]
    return request
}

func httpResponse(status: Int, headers: [String: String], body: String) -> Data {
    httpResponse(status: status, headers: headers, body: Data(body.utf8))
}

func httpResponse(status: Int, headers: [String: String], body: Data) -> Data {
    httpResponseHead(status: status, headers: headers, contentLength: body.count) + body
}

func insertingHeaders(_ headers: [String: String], into response: Data) -> Data {
    guard !headers.isEmpty,
          let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
        return response
    }
    let additions = headers.keys.sorted().compactMap { key in
        headers[key].map { "\(key): \($0)\r\n" }
    }.joined()
    var result = Data(response[..<separator.lowerBound])
    result.append(Data("\r\n".utf8))
    result.append(contentsOf: additions.utf8)
    result.append(Data("\r\n\r\n".utf8))
    result.append(response[separator.upperBound...])
    return result
}

func httpResponseHead(status: Int, headers: [String: String], contentLength: Int? = nil) -> Data {
    var responseHeaders = headers
    if let contentLength {
        responseHeaders["Content-Length"] = "\(contentLength)"
    }
    responseHeaders["Connection"] = "close"
    let head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        + "\r\n\r\n"
    return Data(head.utf8)
}

func typedGatewayErrorResponse(_ error: BurnBarHTTPGatewayError) -> Data {
    let message = error.localizedDescription
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    let body = #"{"error":{"code":"\#(error.responseCode)","message":"\#(message)"}}"#
    return httpResponse(status: error.httpStatus, headers: ["Content-Type": "application/json"], body: body)
}

func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 413: return "Payload Too Large"
    case 404: return "Not Found"
    case 429: return "Too Many Requests"
    case 501: return "Not Implemented"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
}

func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        var offset = 0
        while remaining > 0 {
            let wrote = send(fileDescriptor, baseAddress.advanced(by: offset), remaining, Int32(MSG_NOSIGNAL))
            if wrote < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard wrote > 0 else { throw POSIXError(.EIO) }
            remaining -= wrote
            offset += wrote
        }
    }
}
// cov:ignore-end
#endif
