// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFSchemaValidator — a JSON Schema subset validator, in Swift, in-process.
//
// §10 requires that the validator be **proven to have run**: "a schema gate that
// silently no-ops when its dependency is missing is a known local failure mode".
// Shelling out to `python3 -c 'import jsonschema'` is exactly that failure mode —
// the check passes on any machine where the import fails, which is every machine
// that never installed it. So the validator is vendored here, it runs in the
// same process as the test, and `assertionsEvaluated` is asserted non-zero.
//
// It implements the keywords `contracts/mif-v1.schema.json` actually uses:
// `$ref`, `type`, `enum`, `const`, `required`, `properties`,
// `additionalProperties: false`, `propertyNames`, `pattern`, `not`, `minimum`,
// `maximum`, `minLength`, `minItems`, `maxItems`, `items`, `allOf`, `oneOf`,
// `anyOf`, `if`/`then`/`else`. An UNKNOWN keyword is a hard failure rather than
// a silent skip, so the contract growing a keyword this file cannot check turns
// the suite red instead of quietly weakening it.

import Foundation

struct MIFSchemaViolation: Error, CustomStringConvertible {
    var path: String
    var message: String
    var description: String { "\(path.isEmpty ? "<root>" : path): \(message)" }
}

final class MIFSchemaValidator {
    private let root: [String: Any]
    /// How many schema nodes this validator actually evaluated. A run that
    /// evaluates zero nodes is a run that proved nothing.
    private(set) var assertionsEvaluated = 0

    private static let supportedKeywords: Set<String> = [
        "$ref", "$id", "$schema", "$comment", "title", "description",
        "type", "enum", "const", "required", "properties", "additionalProperties",
        "propertyNames", "pattern", "not", "minimum", "maximum", "minLength",
        "minItems", "maxItems", "items", "allOf", "oneOf", "anyOf",
        "if", "then", "else", "$defs"
    ]

    init(schemaData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw MIFSchemaViolation(path: "", message: "schema is not a JSON object")
        }
        root = object
    }

    /// Validate `value` against the `$def` at `pointer`, e.g.
    /// `#/$defs/record_memory`.
    func validate(_ value: Any, against pointer: String) throws {
        try check(value, schema: resolve(pointer), path: "")
    }

    func resolve(_ pointer: String) throws -> [String: Any] {
        var node: Any = root
        for component in pointer.split(separator: "/") where component != "#" {
            let key = component.replacingOccurrences(of: "~1", with: "/")
            guard let object = node as? [String: Any], let next = object[key] else {
                throw MIFSchemaViolation(path: pointer, message: "unresolvable $ref component \(key)")
            }
            node = next
        }
        guard let schema = node as? [String: Any] else {
            throw MIFSchemaViolation(path: pointer, message: "$ref does not name an object")
        }
        return schema
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length reason: one branch per JSON Schema keyword
    private func check(_ value: Any, schema: [String: Any], path: String) throws {
        assertionsEvaluated += 1

        for key in schema.keys where Self.supportedKeywords.contains(key) == false {
            throw MIFSchemaViolation(path: path, message: "validator does not implement keyword '\(key)'")
        }

        if let reference = schema["$ref"] as? String {
            try check(value, schema: try resolve(reference), path: path)
        }

        if let types = schema["type"] {
            let allowed = (types as? [String]) ?? [types as? String].compactMap { $0 }
            guard allowed.contains(where: { matches(type: $0, value: value) }) else {
                throw MIFSchemaViolation(path: path, message: "expected type \(allowed), got \(describe(value))")
            }
        }

        if let allowed = schema["enum"] as? [Any] {
            guard allowed.contains(where: { equal($0, value) }) else {
                throw MIFSchemaViolation(path: path, message: "\(describe(value)) is not in the closed set")
            }
        }

        if let constant = schema["const"], equal(constant, value) == false {
            throw MIFSchemaViolation(path: path, message: "expected const \(constant), got \(describe(value))")
        }

        if let pattern = schema["pattern"] as? String, let text = value as? String {
            guard text.range(of: pattern, options: .regularExpression) != nil else {
                throw MIFSchemaViolation(path: path, message: "\"\(text)\" does not match \(pattern)")
            }
        }

        if let negated = schema["not"] as? [String: Any] {
            if (try? check(value, schema: negated, path: path)) != nil {
                throw MIFSchemaViolation(path: path, message: "value matched a `not` schema")
            }
        }

        if let text = value as? String {
            if let minLength = schema["minLength"] as? Int, text.count < minLength {
                throw MIFSchemaViolation(path: path, message: "shorter than minLength \(minLength)")
            }
        }

        if let number = numeric(value) {
            if let minimum = numeric(schema["minimum"] as Any?), number < minimum {
                throw MIFSchemaViolation(path: path, message: "\(number) < minimum \(minimum)")
            }
            if let maximum = numeric(schema["maximum"] as Any?), number > maximum {
                throw MIFSchemaViolation(path: path, message: "\(number) > maximum \(maximum)")
            }
        }

        if let array = value as? [Any] {
            if let minItems = schema["minItems"] as? Int, array.count < minItems {
                throw MIFSchemaViolation(path: path, message: "fewer than minItems \(minItems)")
            }
            if let maxItems = schema["maxItems"] as? Int, array.count > maxItems {
                throw MIFSchemaViolation(path: path, message: "more than maxItems \(maxItems)")
            }
            if let items = schema["items"] as? [String: Any] {
                for (index, element) in array.enumerated() {
                    try check(element, schema: items, path: "\(path)[\(index)]")
                }
            }
        }

        if let object = value as? [String: Any] {
            try checkObject(object, schema: schema, path: path)
        }

        for keyword in ["allOf", "anyOf", "oneOf"] {
            guard let branches = schema[keyword] as? [[String: Any]] else { continue }
            let passed = branches.filter { branch in
                (try? check(value, schema: branch, path: path)) != nil
            }.count
            switch keyword {
            case "allOf":
                if passed != branches.count {
                    // Re-run to surface the first real message rather than a count.
                    for branch in branches { try check(value, schema: branch, path: path) }
                }
            case "anyOf" where passed == 0:
                throw MIFSchemaViolation(path: path, message: "matched no anyOf branch")
            case "oneOf" where passed != 1:
                throw MIFSchemaViolation(path: path, message: "matched \(passed) oneOf branches, expected 1")
            default:
                break
            }
        }

        if let condition = schema["if"] as? [String: Any] {
            let matched = (try? check(value, schema: condition, path: path)) != nil
            if matched, let consequent = schema["then"] as? [String: Any] {
                try check(value, schema: consequent, path: path)
            }
            if matched == false, let alternative = schema["else"] as? [String: Any] {
                try check(value, schema: alternative, path: path)
            }
        }
    }

    private func checkObject(_ object: [String: Any], schema: [String: Any], path: String) throws {
        if let required = schema["required"] as? [String] {
            for key in required where object[key] == nil {
                throw MIFSchemaViolation(path: path, message: "missing required property '\(key)'")
            }
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, subschema) in properties {
            guard let present = object[key], let subschema = subschema as? [String: Any] else { continue }
            try check(present, schema: subschema, path: path.isEmpty ? key : "\(path).\(key)")
        }
        if let names = schema["propertyNames"] as? [String: Any] {
            for key in object.keys {
                try check(key, schema: names, path: "\(path).<key \(key)>")
            }
        }
        switch schema["additionalProperties"] {
        case let allowed as Bool where allowed == false:
            for key in object.keys where properties[key] == nil {
                throw MIFSchemaViolation(path: path, message: "additional property '\(key)' is not allowed")
            }
        case let subschema as [String: Any]:
            for (key, present) in object where properties[key] == nil {
                try check(present, schema: subschema, path: path.isEmpty ? key : "\(path).\(key)")
            }
        default:
            break
        }
    }

    // MARK: - JSON helpers

    private func matches(type: String, value: Any) -> Bool {
        switch type {
        case "object": value is [String: Any]
        case "array": value is [Any]
        case "string": value is String
        case "boolean": isBool(value)
        case "integer": isBool(value) == false && numeric(value).map { $0 == $0.rounded() } ?? false
        case "number": isBool(value) == false && numeric(value) != nil
        case "null": value is NSNull
        default: false
        }
    }

    private func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    private func numeric(_ value: Any?) -> Double? {
        guard let value, isBool(value) == false else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull && rhs is NSNull { return true }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if isBool(lhs) || isBool(rhs) {
            guard let left = lhs as? NSNumber, let right = rhs as? NSNumber else { return false }
            return isBool(lhs) == isBool(rhs) && left.boolValue == right.boolValue
        }
        if let left = numeric(lhs), let right = numeric(rhs) { return left == right }
        return false
    }

    private func describe(_ value: Any) -> String {
        value is NSNull ? "null" : "\(value)"
    }
}
