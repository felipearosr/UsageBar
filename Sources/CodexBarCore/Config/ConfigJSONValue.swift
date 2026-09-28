import Foundation

/// A lossless JSON value, used to carry config fragments this build does not understand through a load/save cycle.
public enum ConfigJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConfigJSONValue])
    case object([String: ConfigJSONValue])

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyKey.self) {
            var object: [String: ConfigJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(ConfigJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var array: [ConfigJSONValue] = []
            while !container.isAtEnd {
                try array.append(container.decode(ConfigJSONValue.self))
            }
            self = .array(array)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: AnyKey(key))
            }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(_ string: String) {
            self.stringValue = string
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
