import Foundation

/// A JSON document, held exactly as it arrived.
///
/// ## Why the app needs this at all
///
/// Every other backend this client talks to answers with a payload the app
/// owns the shape of: a list of documents, a plan, a set of markers. openGym
/// is not that. Its state is ONE document written by a web app that optimises
/// for its own reads - short keys (`ex`, `n`, `bp`, `w`, `r`), keys present
/// only when they differ from a default, and a weekday map keyed by
/// Javascript's `getDay()`. A PUT replaces the whole document, so any key a
/// `Codable` struct does not know about is a key this app would DELETE from
/// Arya's profile the first time he ticks a set off on his phone.
///
/// So the document is decoded into this and mutated in place. What the screens
/// need is read through typed views (see `GymState`); everything else rides
/// along untouched and goes back up exactly as it came down.
///
/// ## Why integers are a separate case
///
/// `_ts`, `start` and `end` are millisecond epochs, and `sets`, `reps` and the
/// weekday keys are counts. Round-tripping all of them through `Double` works
/// arithmetically at these magnitudes, but it re-encodes a document full of
/// `80` as a document full of `80` or `80.0` depending on the platform's
/// number formatting - a diff in Arya's training log every time the phone
/// writes. Decoding `Int` first keeps a whole number whole.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:               try container.encodeNil()
        case .bool(let value):    try container.encode(value)
        case .int(let value):     try container.encode(value)
        case .double(let value):  try container.encode(value)
        case .string(let value):  try container.encode(value)
        case .array(let value):   try container.encode(value)
        case .object(let value):  try container.encode(value)
        }
    }

    // MARK: - Reading

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):    return value
        case .double(let value): return Int(value)
        default:                 return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):    return Double(value)
        case .double(let value): return value
        default:                 return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    // MARK: - Writing

    /// A number, written as an integer when it is one.
    ///
    /// Weights are the reason. openGym stores 80 and 82.5 in the same field,
    /// and a client that wrote `80.0` where the web app writes `80` would
    /// churn the document on every save.
    static func number(_ value: Double) -> JSONValue {
        if value.rounded() == value, abs(value) < 1e15 { return .int(Int(value)) }
        return .double(value)
    }
}

extension [String: JSONValue] {
    /// The whole document, as bytes, for a request body or a cache file.
    func jsonData() throws -> Data { try JSONEncoder().encode(self) }
}
