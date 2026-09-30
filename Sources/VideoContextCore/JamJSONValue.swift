import Foundation

/// JSON values owned by the core module, independent of the MCP SDK.
public indirect enum JamJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JamJSONValue])
    case object([String: JamJSONValue])

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var objectValue: [String: JamJSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JamJSONValue]? { if case .array(let value) = self { value } else { nil } }

    public func conforms(to schema: JamJSONValue) -> Bool {
        guard let definition = schema.objectValue else { return true }
        if let choices = definition["enum"]?.arrayValue, !choices.contains(self) { return false }
        if let type = definition["type"]?.stringValue {
            switch (type, self) {
            case ("null", .null), ("boolean", .bool), ("integer", .int), ("number", .int),
                 ("number", .double), ("string", .string), ("array", .array), ("object", .object): break
            default: return false
            }
        }
        if case .array(let values) = self, let itemSchema = definition["items"] {
            guard values.allSatisfy({ $0.conforms(to: itemSchema) }) else { return false }
        }
        if case .object(let values) = self {
            let required = definition["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard required.allSatisfy({ values[$0] != nil }) else { return false }
            let properties = definition["properties"]?.objectValue ?? [:]
            for (key, value) in values {
                if let child = properties[key] {
                    guard value.conforms(to: child) else { return false }
                } else if definition["additionalProperties"] == .bool(false) { return false }
            }
        }
        return true
    }
}
