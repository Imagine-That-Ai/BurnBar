import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension AgentToolBroker {
    static func payload(name: String, response: ComputerUseInvokeResponse) -> AgentToolExecutionPayload {
        var object: [String: Any] = [
            "ok": response.status == .executed,
            "tool": name,
            "status": response.status.rawValue,
            "sessionId": response.sessionId
        ]
        if let approvalId = response.approvalId { object["approvalId"] = approvalId }
        if let denyReason = response.denyReason { object["denyReason"] = denyReason }
        if let auditEntryIndex = response.auditEntryIndex { object["auditEntryIndex"] = auditEntryIndex }
        if let auditHeadHashHex = response.auditHeadHashHex { object["auditHeadHashHex"] = auditHeadHashHex }
        if let result = response.result {
            let jsonResult = jsonObject(from: result.output)
            object["result"] = shouldWrapUntrustedComputerUseResult(toolName: name)
                ? wrappedUntrustedComputerUseResult(jsonResult, toolName: name)
                : jsonResult
            object["succeeded"] = result.succeeded
            object["errorMessage"] = result.errorMessage
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            data = Data("{}".utf8)
        }
        let detail = response.denyReason ?? response.status.rawValue
        return AgentToolExecutionPayload(content: String(decoding: data, as: UTF8.self), detail: detail)
    }

    private static func shouldWrapUntrustedComputerUseResult(toolName: String) -> Bool {
        // T-AI-01: default-deny. Every content-returning computer-use result is
        // wrapped unless the tool is on the tiny control-only allow-list. This
        // replaces the prior 2-tool allowlist (browser extract + AX inspect),
        // which failed open for any new content-returning tool (screenshot OCR,
        // clipboard, file reads, shell stdout/stderr).
        UntrustedToolOutputPolicy.shouldWrap(toolName: toolName)
    }

    private static func wrappedUntrustedComputerUseResult(_ result: Any, toolName: String) -> [String: Any] {
        [
            "contentFormat": "json",
            "provenance": "computer_use_tool_result:\(toolName)",
            "untrustedContent": LLMSafeContent.wrapUntrusted(
                jsonString(from: result),
                provenance: "computer_use_tool_result:\(toolName)"
            )
        ]
    }

    private static func jsonString(from value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value) {
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            } catch {
                return String(describing: value)
            }
        }
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private static func jsonObject(from value: BurnBarJSONValue?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case .string(let string): return string
        case .number(let double): return double
        case .object(let object): return object.mapValues { jsonObject(from: $0) }
        case .array(let array): return array.map { jsonObject(from: $0) }
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }

    static func jsonObject(fromArguments arguments: String) throws -> [String: Any] {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func burnBarJSONValue(fromArguments arguments: String) throws -> BurnBarJSONValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        return try jsonValue(from: JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
    }

    private static func jsonValue(from any: Any) throws -> BurnBarJSONValue {
        switch any {
        case let object as [String: Any]:
            var mapped: [String: BurnBarJSONValue] = [:]
            for (key, value) in object {
                mapped[key] = try jsonValue(from: value)
            }
            return .object(mapped)
        case let array as [Any]:
            return .array(try array.map { try jsonValue(from: $0) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case _ as NSNull:
            return .null
        default:
            throw NSError(domain: "AgentToolBroker", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value"])
        }
    }
}
