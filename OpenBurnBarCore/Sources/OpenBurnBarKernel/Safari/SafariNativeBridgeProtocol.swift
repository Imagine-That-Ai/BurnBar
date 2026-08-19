import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Wire-level limits for the Safari WebExtension → native appex bridge.
///
/// `BurnBarSafariProtocol.maximumInlinePayloadBytes` describes the unencoded
/// payload budget advertised to JavaScript. A base64-encoded 384 KiB chunk is
/// roughly 512 KiB on the native-message wire, so the containing envelope gets
/// a slightly larger bound while the decoded payload remains capped by the
/// canonical Safari contract.
public enum BurnBarSafariBridgeWire {
    public static let protocolVersion = BurnBarSafariProtocol.currentVersion
    public static let maximumInlineMessageBytes = 640 * 1024
    public static let maximumChunkBytes = BurnBarSafariProtocol.maximumInlinePayloadBytes
    public static let maximumChunkedPayloadBytes = BurnBarSafariProtocol.maximumChunkedPayloadBytes
    public static let maximumChunkCount =
        BurnBarSafariProtocol.maximumChunkedPayloadBytes / BurnBarSafariProtocol.maximumInlinePayloadBytes
    public static let maximumNativeResponseBytes = 640 * 1024
    public static let maximumIdentifierLength = 128
    public static let maximumJSONDepth = 32
    public static let maximumCollectionMembers = 8_192
    public static let maximumDaemonSocketRequestBytes = 60 * 1024

    /// Exact marker used when a payload must be externalized before crossing
    /// the daemon's 64 KiB socket-request boundary.
    public static let appGroupPayloadMarkerKey = "$openburnbarSafariAppGroupPayload"
}

public enum BurnBarSafariBridgeMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case hello = "bridge.hello"
    case poll = "bridge.poll"
    case complete = "bridge.complete"
    case popupAction = "bridge.popupAction"
    case chunkBegin = "bridge.chunk.begin"
    case chunkAppend = "bridge.chunk.append"
    case chunkCommit = "bridge.chunk.commit"

    public var isChunkMethod: Bool {
        switch self {
        case .chunkBegin, .chunkAppend, .chunkCommit:
            return true
        case .hello, .poll, .complete, .popupAction:
            return false
        }
    }
}

public struct BurnBarSafariBridgeErrorPayload: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: BurnBarJSONValue?

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: BurnBarJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct BurnBarSafariBridgeFailure: Error, LocalizedError, Hashable, Sendable {
    public let payload: BurnBarSafariBridgeErrorPayload

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: BurnBarJSONValue? = nil
    ) {
        self.payload = BurnBarSafariBridgeErrorPayload(
            code: code,
            message: message,
            retryable: retryable,
            details: details
        )
    }

    public var errorDescription: String? { payload.message }
}

public struct BurnBarSafariNativeRequestEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let method: BurnBarSafariBridgeMethod
    public let params: [String: BurnBarJSONValue]

    public init(
        protocolVersion: Int = BurnBarSafariBridgeWire.protocolVersion,
        id: String,
        method: BurnBarSafariBridgeMethod,
        params: [String: BurnBarJSONValue]
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct BurnBarSafariNativeResponseEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let result: BurnBarJSONValue?
    public let error: BurnBarSafariBridgeErrorPayload?

    public init(
        protocolVersion: Int = BurnBarSafariBridgeWire.protocolVersion,
        id: String,
        result: BurnBarJSONValue? = nil,
        error: BurnBarSafariBridgeErrorPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: String, result: BurnBarJSONValue) -> Self {
        Self(id: id, result: result)
    }

    public static func failure(id: String, error: BurnBarSafariBridgeErrorPayload) -> Self {
        Self(id: id, error: error)
    }
}

/// Strict codec for Safari native-message envelopes.
///
/// The WebExtension boundary intentionally uses ISO-8601 strings, accepting
/// both whole-second and fractional-second forms. The daemon socket continues
/// to use the repository's default Swift Codable `Date` representation. The
/// native controller decodes web payloads with this codec, then re-encodes typed
/// daemon requests with an ordinary `JSONEncoder`; daemon responses take the
/// reverse path. Keeping the translation here avoids changing the global daemon
/// wire format and makes the format boundary directly testable.
public enum BurnBarSafariNativeBridgeCodec {
    public static func decodeRequest(
        from propertyList: Any,
        maximumBytes: Int = BurnBarSafariBridgeWire.maximumInlineMessageBytes
    ) throws -> BurnBarSafariNativeRequestEnvelope {
        guard JSONSerialization.isValidJSONObject(propertyList) else {
            throw failure("invalid_bridge_schema", "Native request must be a JSON object.")
        }
        let data = try JSONSerialization.data(withJSONObject: propertyList, options: [])
        return try decodeRequest(from: data, maximumBytes: maximumBytes)
    }

    public static func decodeRequest(
        from data: Data,
        maximumBytes: Int = BurnBarSafariBridgeWire.maximumInlineMessageBytes
    ) throws -> BurnBarSafariNativeRequestEnvelope {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw failure(
                "bridge_payload_too_large",
                "Safari native request exceeds the \(maximumBytes)-byte bridge limit."
            )
        }
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = raw as? [String: Any] else {
            throw failure("invalid_bridge_schema", "Native request must be a JSON object.")
        }
        try validateExactKeys(
            object,
            allowed: ["protocolVersion", "id", "method", "params"],
            label: "request"
        )

        guard let protocolVersion = integer(object["protocolVersion"]),
              protocolVersion == BurnBarSafariBridgeWire.protocolVersion else {
            throw failure("protocol_mismatch", "Unsupported Safari bridge protocol version.")
        }
        let id = try requiredIdentifier(object["id"], label: "request.id")
        guard let methodRaw = object["method"] as? String,
              let method = BurnBarSafariBridgeMethod(rawValue: methodRaw) else {
            throw failure("invalid_bridge_method", "Unsupported Safari bridge method.")
        }
        guard let paramsObject = object["params"] as? [String: Any] else {
            throw failure("invalid_bridge_schema", "request.params must be an object.")
        }
        try validateJSONTree(paramsObject, depth: 0)
        try validateParams(paramsObject, for: method)

        let params = try paramsObject.mapValues { try jsonValue(from: $0, depth: 0) }
        return BurnBarSafariNativeRequestEnvelope(
            protocolVersion: protocolVersion,
            id: id,
            method: method,
            params: params
        )
    }

    public static func encodeResponseObject(
        _ response: BurnBarSafariNativeResponseEnvelope
    ) throws -> Any {
        guard (response.result == nil) != (response.error == nil) else {
            throw failure(
                "invalid_bridge_schema",
                "Native response must contain exactly one of result or error."
            )
        }
        let data = try JSONEncoder().encode(response)
        guard data.count <= BurnBarSafariBridgeWire.maximumNativeResponseBytes else {
            throw failure(
                "bridge_response_too_large",
                "Safari native response exceeds the native-message response limit."
            )
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    public static func decodeWebValue<Value: Decodable>(
        _ type: Value.Type,
        from value: BurnBarJSONValue
    ) throws -> Value {
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ThreadSafeISO8601DateFormatter.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp with optional fractional seconds."
                )
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }

    public static func decodeWebParams<Value: Decodable>(
        _ type: Value.Type,
        from params: [String: BurnBarJSONValue]
    ) throws -> Value {
        try decodeWebValue(type, from: .object(params))
    }

    public static func encodeWebValue<Value: Encodable>(_ value: Value) throws -> BurnBarJSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(BurnBarJSONValue.self, from: data)
    }

    public static func daemonJSONValue<Value: Encodable>(_ value: Value) throws -> BurnBarJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(BurnBarJSONValue.self, from: data)
    }

    public static func decodeDaemonValue<Value: Decodable>(
        _ type: Value.Type,
        from value: BurnBarJSONValue
    ) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func validateParams(
        _ params: [String: Any],
        for method: BurnBarSafariBridgeMethod
    ) throws {
        switch method {
        case .hello:
            try validateExactKeys(
                params,
                allowed: [
                    "extensionInstanceId", "clientName", "supportedProtocolVersions",
                    "activePage", "capabilities"
                ],
                label: "bridge.hello.params"
            )
            _ = try requiredIdentifier(
                params["extensionInstanceId"],
                label: "bridge.hello.params.extensionInstanceId"
            )
            _ = try requiredString(
                params["clientName"],
                label: "bridge.hello.params.clientName",
                maximumLength: 128
            )
            guard let versions = params["supportedProtocolVersions"] as? [Any],
                  !versions.isEmpty,
                  versions.count <= 8,
                  versions.allSatisfy({ integer($0) != nil }) else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.hello.params.supportedProtocolVersions must be a non-empty integer array."
                )
            }
            if let activePage = params["activePage"], !(activePage is NSNull) {
                try validatePageState(activePage, label: "bridge.hello.params.activePage")
            }
            guard let capabilities = params["capabilities"] as? [String: Any] else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.hello.params.capabilities must be an object."
                )
            }
            try validateExactKeys(
                capabilities,
                allowed: [
                    "captureVisibleTab", "scripting", "nativeMessaging",
                    "activeTabPermission", "siteAccessGranted"
                ],
                label: "bridge.hello.params.capabilities"
            )
            for key in capabilities.keys {
                guard capabilities[key] is Bool else {
                    throw failure(
                        "invalid_bridge_schema",
                        "bridge.hello.params.capabilities.\(key) must be boolean."
                    )
                }
            }

        case .poll:
            try validateExactKeys(
                params,
                allowed: ["sessionId", "activePage", "knownTabs"],
                label: "bridge.poll.params"
            )
            _ = try requiredIdentifier(params["sessionId"], label: "bridge.poll.params.sessionId")
            if let activePage = params["activePage"], !(activePage is NSNull) {
                try validatePageState(activePage, label: "bridge.poll.params.activePage")
            }
            guard let tabs = params["knownTabs"] as? [Any], tabs.count <= 512 else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.poll.params.knownTabs must be a bounded array."
                )
            }
            for (index, tab) in tabs.enumerated() {
                try validateTabState(tab, label: "bridge.poll.params.knownTabs[\(index)]")
            }

        case .complete:
            try validateExactKeys(
                params,
                allowed: ["sessionId", "commandId", "ok", "result", "error", "pageState", "tabs"],
                label: "bridge.complete.params"
            )
            _ = try requiredIdentifier(params["sessionId"], label: "bridge.complete.params.sessionId")
            _ = try requiredIdentifier(params["commandId"], label: "bridge.complete.params.commandId")
            guard params["ok"] is Bool else {
                throw failure("invalid_bridge_schema", "bridge.complete.params.ok must be boolean.")
            }
            if let error = params["error"], !(error is NSNull) {
                _ = try requiredString(
                    error,
                    label: "bridge.complete.params.error",
                    maximumLength: 8_192
                )
            }
            try validatePageState(params["pageState"], label: "bridge.complete.params.pageState")
            guard let tabs = params["tabs"] as? [Any], tabs.count <= 512 else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.complete.params.tabs must be a bounded array."
                )
            }
            for (index, tab) in tabs.enumerated() {
                try validateTabState(tab, label: "bridge.complete.params.tabs[\(index)]")
            }

        case .popupAction:
            try validateExactKeys(
                params,
                allowed: ["sessionId", "action", "payload"],
                label: "bridge.popupAction.params"
            )
            _ = try requiredIdentifier(
                params["sessionId"],
                label: "bridge.popupAction.params.sessionId"
            )
            _ = try requiredString(
                params["action"],
                label: "bridge.popupAction.params.action",
                maximumLength: 128
            )
            guard params["payload"] is [String: Any] else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.popupAction.params.payload must be an object."
                )
            }

        case .chunkBegin:
            try validateExactKeys(
                params,
                allowed: ["transferId", "originalMethod", "byteLength", "chunkCount", "sha256"],
                label: "bridge.chunk.begin.params"
            )
            _ = try requiredIdentifier(
                params["transferId"],
                label: "bridge.chunk.begin.params.transferId"
            )
            guard let methodRaw = params["originalMethod"] as? String,
                  let originalMethod = BurnBarSafariBridgeMethod(rawValue: methodRaw),
                  !originalMethod.isChunkMethod else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.chunk.begin.params.originalMethod is invalid."
                )
            }
            guard let byteLength = integer(params["byteLength"]),
                  byteLength > 0,
                  byteLength <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
                throw failure(
                    "bridge_payload_too_large",
                    "bridge.chunk.begin.params.byteLength is outside the supported range."
                )
            }
            guard let chunkCount = integer(params["chunkCount"]),
                  chunkCount > 0,
                  chunkCount <= BurnBarSafariBridgeWire.maximumChunkCount else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.chunk.begin.params.chunkCount is outside the supported range."
                )
            }
            let sha256 = try requiredString(
                params["sha256"],
                label: "bridge.chunk.begin.params.sha256",
                maximumLength: 64
            )
            guard sha256.count == 64,
                  sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.chunk.begin.params.sha256 must be lowercase hexadecimal."
                )
            }

        case .chunkAppend:
            try validateExactKeys(
                params,
                allowed: ["transferId", "index", "data"],
                label: "bridge.chunk.append.params"
            )
            _ = try requiredIdentifier(
                params["transferId"],
                label: "bridge.chunk.append.params.transferId"
            )
            guard let index = integer(params["index"]),
                  index >= 0,
                  index < BurnBarSafariBridgeWire.maximumChunkCount else {
                throw failure(
                    "invalid_bridge_schema",
                    "bridge.chunk.append.params.index is outside the supported range."
                )
            }
            let maximumEncodedLength = ((BurnBarSafariBridgeWire.maximumChunkBytes + 2) / 3) * 4
            _ = try requiredString(
                params["data"],
                label: "bridge.chunk.append.params.data",
                maximumLength: maximumEncodedLength
            )

        case .chunkCommit:
            try validateExactKeys(
                params,
                allowed: ["transferId"],
                label: "bridge.chunk.commit.params"
            )
            _ = try requiredIdentifier(
                params["transferId"],
                label: "bridge.chunk.commit.params.transferId"
            )
        }
    }

    private static func validatePageState(_ value: Any?, label: String) throws {
        guard let object = value as? [String: Any] else {
            throw failure("invalid_bridge_schema", "\(label) must be an object.")
        }
        try validateExactKeys(
            object,
            allowed: [
                "tabId", "windowId", "url", "title", "navigationEpoch",
                "isActive", "isTopFrame", "capturedAt"
            ],
            label: label
        )
        guard let tabID = integer(object["tabId"]), tabID >= 0,
              let epoch = integer(object["navigationEpoch"]), epoch >= 0,
              object["isActive"] is Bool,
              object["isTopFrame"] is Bool else {
            throw failure("invalid_bridge_schema", "\(label) contains invalid state fields.")
        }
        if let windowID = object["windowId"], !(windowID is NSNull) {
            guard let parsed = integer(windowID), parsed >= 0 else {
                throw failure("invalid_bridge_schema", "\(label).windowId must be non-negative.")
            }
        }
        _ = try requiredString(object["url"], label: "\(label).url", maximumLength: 16_384)
        _ = try requiredString(object["title"], label: "\(label).title", maximumLength: 8_192)
        _ = try requiredISO8601String(object["capturedAt"], label: "\(label).capturedAt")
    }

    private static func validateTabState(_ value: Any, label: String) throws {
        guard let object = value as? [String: Any] else {
            throw failure("invalid_bridge_schema", "\(label) must be an object.")
        }
        try validateExactKeys(
            object,
            allowed: [
                "tabId", "windowId", "url", "title", "isActive", "isOwned", "navigationEpoch"
            ],
            label: label
        )
        guard let tabID = integer(object["tabId"]), tabID >= 0,
              let epoch = integer(object["navigationEpoch"]), epoch >= 0,
              object["isActive"] is Bool,
              object["isOwned"] is Bool else {
            throw failure("invalid_bridge_schema", "\(label) contains invalid tab fields.")
        }
        if let windowID = object["windowId"], !(windowID is NSNull) {
            guard let parsed = integer(windowID), parsed >= 0 else {
                throw failure("invalid_bridge_schema", "\(label).windowId must be non-negative.")
            }
        }
        _ = try requiredString(object["url"], label: "\(label).url", maximumLength: 16_384)
        _ = try requiredString(object["title"], label: "\(label).title", maximumLength: 8_192)
    }

    private static func validateJSONTree(_ value: Any, depth: Int) throws {
        guard depth <= BurnBarSafariBridgeWire.maximumJSONDepth else {
            throw failure("invalid_bridge_schema", "Safari bridge JSON exceeds the nesting limit.")
        }
        switch value {
        case let object as [String: Any]:
            guard object.count <= BurnBarSafariBridgeWire.maximumCollectionMembers else {
                throw failure("invalid_bridge_schema", "Safari bridge object contains too many fields.")
            }
            for (key, child) in object {
                guard !key.isEmpty, key.utf8.count <= 256 else {
                    throw failure("invalid_bridge_schema", "Safari bridge object contains an invalid key.")
                }
                try validateJSONTree(child, depth: depth + 1)
            }
        case let array as [Any]:
            guard array.count <= BurnBarSafariBridgeWire.maximumCollectionMembers else {
                throw failure("invalid_bridge_schema", "Safari bridge array contains too many elements.")
            }
            for child in array {
                try validateJSONTree(child, depth: depth + 1)
            }
        case let number as NSNumber:
            if !isBoolean(number) {
                guard number.doubleValue.isFinite else {
                    throw failure("invalid_bridge_schema", "Safari bridge number must be finite.")
                }
            }
        case is String, is NSNull:
            break
        default:
            throw failure("invalid_bridge_schema", "Safari bridge contains a non-JSON value.")
        }
    }

    private static func jsonValue(from value: Any, depth: Int) throws -> BurnBarJSONValue {
        guard depth <= BurnBarSafariBridgeWire.maximumJSONDepth else {
            throw failure("invalid_bridge_schema", "Safari bridge JSON exceeds the nesting limit.")
        }
        if let object = value as? [String: Any] {
            return .object(try object.mapValues { try jsonValue(from: $0, depth: depth + 1) })
        }
        if let array = value as? [Any] {
            return .array(try array.map { try jsonValue(from: $0, depth: depth + 1) })
        }
        if let string = value as? String {
            return .string(string)
        }
        if value is NSNull {
            return .null
        }
        if let number = value as? NSNumber {
            if isBoolean(number) {
                return .bool(number.boolValue)
            }
            guard number.doubleValue.isFinite else {
                throw failure("invalid_bridge_schema", "Safari bridge number must be finite.")
            }
            return .number(number.doubleValue)
        }
        throw failure("invalid_bridge_schema", "Safari bridge contains a non-JSON value.")
    }

    private static func validateExactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        label: String
    ) throws {
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw failure(
                "invalid_bridge_schema",
                "\(label) contains unknown field \"\(unknown)\"."
            )
        }
    }

    private static func requiredIdentifier(_ value: Any?, label: String) throws -> String {
        let identifier = try requiredString(
            value,
            label: label,
            maximumLength: BurnBarSafariBridgeWire.maximumIdentifierLength
        )
        guard !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure("invalid_bridge_schema", "\(label) contains control characters.")
        }
        return identifier
    }

    private static func requiredString(
        _ value: Any?,
        label: String,
        maximumLength: Int
    ) throws -> String {
        guard let string = value as? String,
              !string.isEmpty,
              string.utf8.count <= maximumLength else {
            throw failure(
                "invalid_bridge_schema",
                "\(label) must be a non-empty string of at most \(maximumLength) bytes."
            )
        }
        return string
    }

    private static func requiredISO8601String(_ value: Any?, label: String) throws -> String {
        let string = try requiredString(value, label: label, maximumLength: 64)
        guard ThreadSafeISO8601DateFormatter.parse(string) != nil else {
            throw failure(
                "invalid_bridge_schema",
                "\(label) must be an ISO-8601 timestamp with optional fractional seconds."
            )
        }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              !isBoolean(number),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation has no standalone CoreFoundation module.
        return String(cString: number.objCType) == "c"
        #endif
    }

    private static func failure(_ code: String, _ message: String) -> BurnBarSafariBridgeFailure {
        BurnBarSafariBridgeFailure(code: code, message: message)
    }
}
