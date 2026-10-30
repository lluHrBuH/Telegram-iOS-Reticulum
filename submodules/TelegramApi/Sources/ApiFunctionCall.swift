import Foundation
import TelegramApiObjC

/// A serialized `Api.functions.*` call decoded back into its typed arguments: what an in-process
/// server (the Reticulum backend's local server, which answers the client's own requests) dispatches
/// on. Built by `Api.parseFunctionCall`; the argument object is the same TLObject a builder makes, so
/// the description, serialization and result parsing are the engine's own.
public final class ApiFunctionCall {
    /// The function's schema name, e.g. `messages.sendMessage`.
    public let name: String
    /// The arguments in schema order, named as the generated builders name them (camelCased):
    /// `Int32`, `Int64`, `Double`, `Int256`, `String`, `Buffer`, an `Api.*` enum value, or an array
    /// of those; `nil` for an optional argument the call left out.
    public let arguments: [(String, Any?)]

    private let object: TLObject
    private let info: UnsafePointer<TLFunctionInfo>

    init(object: TLObject) {
        self.object = object
        self.info = TLObjectFunctionInfo(object)
        self.name = String(cString: self.info.pointee.constructor.name)
        self.arguments = tlDescriptionFields(object).1.map { ($0.0, $0.1.value) }
    }

    /// The argument named `name` as `T`; `nil` when the call left it out or it is not a `T`.
    public func argument<T>(_ name: String) -> T? {
        for (argumentName, value) in self.arguments where argumentName == name {
            return value as? T
        }
        return nil
    }

    /// A vector argument's elements as `[T]`; `nil` when absent, `[]` when present and empty.
    public func elements<T>(_ name: String) -> [T]? {
        guard let values: [Any] = self.argument(name) else {
            if let typed: [T] = self.argument(name) {
                return typed
            }
            return nil
        }
        return values.compactMap { $0 as? T }
    }

    /// Parses `buffer` as this function's result, exactly as the request's `DeserializeFunctionResponse` does.
    public func parseResult(_ buffer: Buffer) -> Any? {
        return tlParseFunctionResult(buffer, self.info)
    }

    /// The call's bytes again (id first), identical to what the builder produced.
    public func serialized() -> Buffer {
        return Buffer(data: tlSerializedData(self.object, boxed: true))
    }
}

extension Api {
    /// Decodes a serialized function call (`NetworkEngineRequest.payload`). `nil` for an unknown
    /// function id (reported to the unknown-constructor log) or a truncated body.
    public static func parseFunctionCall(_ buffer: Buffer) -> ApiFunctionCall? {
        let reader = BufferReader(buffer)
        return tlWithReader(reader) { tlReader -> ApiFunctionCall? in
            TLParseFunctionCall(&tlReader).map { ApiFunctionCall(object: $0) }
        }
    }

    /// Serializes a function result as the server does, so the request's parser reads it back: a
    /// boxed `Api.*` value, or a `Vector` of `Api.*` values, `Int32`, `Int64`, `String` or `Buffer`.
    /// `nil` for anything else.
    public static func serializeFunctionResult(_ result: Any) -> Buffer? {
        let buffer = Buffer()
        if let object = result as? TLObjectBacked {
            object.serialize(buffer, true)
            return buffer
        }
        buffer.appendInt32(481674261)
        switch result {
        case let values as [Int32]:
            buffer.appendInt32(Int32(values.count))
            for value in values {
                buffer.appendInt32(value)
            }
        case let values as [Int64]:
            buffer.appendInt32(Int32(values.count))
            for value in values {
                buffer.appendInt64(value)
            }
        case let values as [String]:
            buffer.appendInt32(Int32(values.count))
            for value in values {
                serializeString(value, buffer: buffer, boxed: false)
            }
        case let values as [Buffer]:
            buffer.appendInt32(Int32(values.count))
            for value in values {
                serializeBytes(value, buffer: buffer, boxed: false)
            }
        case let values as [Any]:
            buffer.appendInt32(Int32(values.count))
            for value in values {
                guard let object = value as? TLObjectBacked else {
                    return nil
                }
                object.serialize(buffer, true)
            }
        default:
            return nil
        }
        return buffer
    }
}
