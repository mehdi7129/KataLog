import Foundation

/// Unknown ULog metadata remains typed. In particular a uint64 is never
/// converted through Double, which would lose controller or serial bits.
public enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .unsigned(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
    public var description: String {
        switch self {
        case .null: return "—"
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .unsigned(let value): return String(value)
        case .number(let value): return String(value)
        default:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "—"
        }
    }
    public subscript(_ key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }
    public var countValue: Int {
        switch self {
        case .integer(let value): return Int(exactly: value) ?? 0
        case .unsigned(let value): return Int(exactly: value) ?? 0
        case .array(let values): return values.count
        default: return 0
        }
    }
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
