import AgentBoardServer
import Foundation

enum ToolSchema {
    static func object(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(_ description: String? = nil, maxLength: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string")]
        if let description { fields["description"] = .string(description) }
        if let maxLength { fields["maxLength"] = .number(Double(maxLength)) }
        return .object(fields)
    }

    static func enumeration(_ values: [String], _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string"), "enum": .array(values.map(JSONValue.string))]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    static func stringArray(_ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("array"), "items": .object(["type": .string("string")])]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }
}

enum ToolArguments {
    static func requiredString(_ key: String, in arguments: JSONValue) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw ToolError("Missing required argument: \(key)")
        }
        return value
    }

    static func optionalString(_ key: String, in arguments: JSONValue) -> String? {
        guard let value = arguments[key], value != .null else { return nil }
        return value.stringValue
    }

    static func stringArray(_ key: String, in arguments: JSONValue) throws -> [String]? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let items = value.arrayValue else {
            throw ToolError("Argument \(key) must be an array of strings")
        }
        return try items.map { item in
            guard let s = item.stringValue else { throw ToolError("Argument \(key) must be an array of strings") }
            return s
        }
    }
}

extension JSONValue {
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    static func millis(_ value: Int64?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }
}
