import Foundation

public enum BurnBarProviderExecutorError: Error, LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case upstreamError(Int, String)
    case upstreamErrorWithHeaders(Int, String, [String: String])

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid OpenBurnBar provider base URL: \(baseURL)"
        case .invalidResponse:
            return "OpenBurnBar provider returned an invalid response."
        case .upstreamError(let statusCode, let body),
             .upstreamErrorWithHeaders(let statusCode, let body, _):
            return "OpenBurnBar provider request failed with status \(statusCode): \(body)"
        }
    }

    var upstreamStatusAndBody: (statusCode: Int, body: String)? {
        switch self {
        case .upstreamError(let statusCode, let body),
             .upstreamErrorWithHeaders(let statusCode, let body, _):
            return (statusCode, body)
        case .invalidBaseURL, .invalidResponse:
            return nil
        }
    }

    var upstreamHeaders: [String: String] {
        guard case .upstreamErrorWithHeaders(_, _, let headers) = self else { return [:] }
        return headers
    }

    static func isTransientCapacityFailure(statusCode: Int, body _: String) -> Bool {
        return statusCode == 529
    }

    /// Rejects non-HTTP(S) provider endpoints (e.g. `file://`, `javascript:`) before outbound requests.
    static func validatedProviderBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let url = URL(string: trimmed) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(rawValue)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.isEmpty == false else {
            throw BurnBarProviderExecutorError.invalidBaseURL(rawValue)
        }
        return url
    }
}
