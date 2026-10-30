import Foundation

/// A MessagePack value, enough for LXMF's `fields` map (integer keys; strings, bytes, integers,
/// floats, booleans, arrays and maps as values). Encoding is canonical (smallest width), decoding
/// accepts every width. Pure Swift, so the local server reads a peer's fields without the Rust
/// side and tests run without it.
public indirect enum MsgPackValue: Equatable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([(key: MsgPackValue, value: MsgPackValue)])

    public static func == (lhs: MsgPackValue, rhs: MsgPackValue) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil):
            return true
        case let (.bool(l), .bool(r)):
            return l == r
        case let (.int(l), .int(r)):
            return l == r
        case let (.uint(l), .uint(r)):
            return l == r
        case let (.int(l), .uint(r)):
            return l >= 0 && UInt64(l) == r
        case let (.uint(l), .int(r)):
            return r >= 0 && l == UInt64(r)
        case let (.float(l), .float(r)):
            return l == r
        case let (.string(l), .string(r)):
            return l == r
        case let (.binary(l), .binary(r)):
            return l == r
        case let (.array(l), .array(r)):
            return l == r
        case let (.map(l), .map(r)):
            guard l.count == r.count else {
                return false
            }
            for (a, b) in zip(l, r) {
                if a.key != b.key || a.value != b.value {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    public var intValue: Int64? {
        switch self {
        case let .int(value):
            return value
        case let .uint(value):
            return value <= UInt64(Int64.max) ? Int64(value) : nil
        case let .float(value):
            return value == value.rounded() && abs(value) < 9.0e18 ? Int64(value) : nil
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .float(value):
            return value
        case let .int(value):
            return Double(value)
        case let .uint(value):
            return Double(value)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var binaryValue: Data? {
        switch self {
        case let .binary(value):
            return value
        case let .string(value):
            return value.data(using: .utf8)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [MsgPackValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    public var mapValue: [(key: MsgPackValue, value: MsgPackValue)]? {
        if case let .map(value) = self {
            return value
        }
        return nil
    }

    /// The value under integer key `key` of a map (LXMF field ids), the last one when repeated.
    public subscript(key: Int64) -> MsgPackValue? {
        guard case let .map(entries) = self else {
            return nil
        }
        var found: MsgPackValue?
        for entry in entries where entry.key.intValue == key {
            found = entry.value
        }
        return found
    }

    public func encoded() -> Data {
        var data = Data()
        self.encode(into: &data)
        return data
    }

    private func encode(into data: inout Data) {
        switch self {
        case .nil:
            data.append(0xc0)
        case let .bool(value):
            data.append(value ? 0xc3 : 0xc2)
        case let .int(value):
            if value >= 0 {
                MsgPackValue.uint(UInt64(value)).encode(into: &data)
            } else if value >= -32 {
                data.append(UInt8(bitPattern: Int8(value)))
            } else if value >= Int64(Int8.min) {
                data.append(0xd0)
                data.append(UInt8(bitPattern: Int8(value)))
            } else if value >= Int64(Int16.min) {
                data.append(0xd1)
                MsgPackValue.appendBigEndian(UInt16(bitPattern: Int16(value)), to: &data)
            } else if value >= Int64(Int32.min) {
                data.append(0xd2)
                MsgPackValue.appendBigEndian(UInt32(bitPattern: Int32(value)), to: &data)
            } else {
                data.append(0xd3)
                MsgPackValue.appendBigEndian(UInt64(bitPattern: value), to: &data)
            }
        case let .uint(value):
            if value < 0x80 {
                data.append(UInt8(value))
            } else if value <= UInt64(UInt8.max) {
                data.append(0xcc)
                data.append(UInt8(value))
            } else if value <= UInt64(UInt16.max) {
                data.append(0xcd)
                MsgPackValue.appendBigEndian(UInt16(value), to: &data)
            } else if value <= UInt64(UInt32.max) {
                data.append(0xce)
                MsgPackValue.appendBigEndian(UInt32(value), to: &data)
            } else {
                data.append(0xcf)
                MsgPackValue.appendBigEndian(value, to: &data)
            }
        case let .float(value):
            data.append(0xcb)
            MsgPackValue.appendBigEndian(value.bitPattern, to: &data)
        case let .string(value):
            let bytes = Data(value.utf8)
            MsgPackValue.appendLength(bytes.count, fix: (0xa0, 31), widths: (0xd9, 0xda, 0xdb), to: &data)
            data.append(bytes)
        case let .binary(value):
            MsgPackValue.appendLength(value.count, fix: nil, widths: (0xc4, 0xc5, 0xc6), to: &data)
            data.append(value)
        case let .array(values):
            MsgPackValue.appendLength(values.count, fix: (0x90, 15), widths: (nil, 0xdc, 0xdd), to: &data)
            for value in values {
                value.encode(into: &data)
            }
        case let .map(entries):
            MsgPackValue.appendLength(entries.count, fix: (0x80, 15), widths: (nil, 0xde, 0xdf), to: &data)
            for entry in entries {
                entry.key.encode(into: &data)
                entry.value.encode(into: &data)
            }
        }
    }

    private static func appendLength(_ length: Int, fix: (UInt8, Int)?, widths: (UInt8?, UInt8, UInt8), to data: inout Data) {
        if let fix = fix, length <= fix.1 {
            data.append(fix.0 | UInt8(length))
        } else if let narrow = widths.0, length <= Int(UInt8.max) {
            data.append(narrow)
            data.append(UInt8(length))
        } else if length <= Int(UInt16.max) {
            data.append(widths.1)
            appendBigEndian(UInt16(length), to: &data)
        } else {
            data.append(widths.2)
            appendBigEndian(UInt32(length), to: &data)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    /// Decodes exactly one value; nil when the bytes are not one complete value.
    public static func decode(_ data: Data) -> MsgPackValue? {
        var reader = Reader(data: data)
        guard let value = reader.readValue(), reader.isAtEnd else {
            return nil
        }
        return value
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var isAtEnd: Bool {
            return self.offset >= self.data.endIndex
        }

        mutating func readByte() -> UInt8? {
            guard self.offset < self.data.endIndex else {
                return nil
            }
            let byte = self.data[self.offset]
            self.offset += 1
            return byte
        }

        mutating func readBytes(_ count: Int) -> Data? {
            guard count >= 0, self.offset + count <= self.data.endIndex else {
                return nil
            }
            let result = self.data.subdata(in: self.offset ..< self.offset + count)
            self.offset += count
            return result
        }

        mutating func readBigEndian<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            guard let bytes = self.readBytes(MemoryLayout<T>.size) else {
                return nil
            }
            var value: T = 0
            for byte in bytes {
                value = (value << 8) | T(byte)
            }
            return value
        }

        mutating func readValue() -> MsgPackValue? {
            guard let marker = self.readByte() else {
                return nil
            }
            switch marker {
            case 0x00 ... 0x7f:
                return .uint(UInt64(marker))
            case 0x80 ... 0x8f:
                return self.readMap(count: Int(marker & 0x0f))
            case 0x90 ... 0x9f:
                return self.readArray(count: Int(marker & 0x0f))
            case 0xa0 ... 0xbf:
                return self.readString(count: Int(marker & 0x1f))
            case 0xc0:
                return .nil
            case 0xc2:
                return .bool(false)
            case 0xc3:
                return .bool(true)
            case 0xc4:
                return self.readByte().flatMap { self.readBytes(Int($0)) }.map(MsgPackValue.binary)
            case 0xc5:
                return self.readBigEndian(UInt16.self).flatMap { self.readBytes(Int($0)) }.map(MsgPackValue.binary)
            case 0xc6:
                return self.readBigEndian(UInt32.self).flatMap { self.readBytes(Int($0)) }.map(MsgPackValue.binary)
            case 0xc7:
                guard let length = self.readByte(), self.readByte() != nil, let bytes = self.readBytes(Int(length)) else { return nil }
                return .binary(bytes)
            case 0xc8:
                guard let length = self.readBigEndian(UInt16.self), self.readByte() != nil, let bytes = self.readBytes(Int(length)) else { return nil }
                return .binary(bytes)
            case 0xc9:
                guard let length = self.readBigEndian(UInt32.self), self.readByte() != nil, let bytes = self.readBytes(Int(length)) else { return nil }
                return .binary(bytes)
            case 0xca:
                return self.readBigEndian(UInt32.self).map { .float(Double(Float(bitPattern: $0))) }
            case 0xcb:
                return self.readBigEndian(UInt64.self).map { .float(Double(bitPattern: $0)) }
            case 0xcc:
                return self.readByte().map { .uint(UInt64($0)) }
            case 0xcd:
                return self.readBigEndian(UInt16.self).map { .uint(UInt64($0)) }
            case 0xce:
                return self.readBigEndian(UInt32.self).map { .uint(UInt64($0)) }
            case 0xcf:
                return self.readBigEndian(UInt64.self).map { .uint($0) }
            case 0xd0:
                return self.readByte().map { .int(Int64(Int8(bitPattern: $0))) }
            case 0xd1:
                return self.readBigEndian(UInt16.self).map { .int(Int64(Int16(bitPattern: $0))) }
            case 0xd2:
                return self.readBigEndian(UInt32.self).map { .int(Int64(Int32(bitPattern: $0))) }
            case 0xd3:
                return self.readBigEndian(UInt64.self).map { .int(Int64(bitPattern: $0)) }
            case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8:
                let length = [1, 2, 4, 8, 16][Int(marker - 0xd4)]
                guard self.readByte() != nil, let bytes = self.readBytes(length) else { return nil }
                return .binary(bytes)
            case 0xd9:
                return self.readByte().flatMap { self.readString(count: Int($0)) }
            case 0xda:
                return self.readBigEndian(UInt16.self).flatMap { self.readString(count: Int($0)) }
            case 0xdb:
                return self.readBigEndian(UInt32.self).flatMap { self.readString(count: Int($0)) }
            case 0xdc:
                return self.readBigEndian(UInt16.self).flatMap { self.readArray(count: Int($0)) }
            case 0xdd:
                return self.readBigEndian(UInt32.self).flatMap { self.readArray(count: Int($0)) }
            case 0xde:
                return self.readBigEndian(UInt16.self).flatMap { self.readMap(count: Int($0)) }
            case 0xdf:
                return self.readBigEndian(UInt32.self).flatMap { self.readMap(count: Int($0)) }
            case 0xe0 ... 0xff:
                return .int(Int64(Int8(bitPattern: marker)))
            default:
                return nil
            }
        }

        mutating func readString(count: Int) -> MsgPackValue? {
            guard let bytes = self.readBytes(count) else {
                return nil
            }
            // LXMF peers may put raw bytes where a string is expected; keep them readable as binary.
            if let string = String(data: bytes, encoding: .utf8) {
                return .string(string)
            }
            return .binary(bytes)
        }

        mutating func readArray(count: Int) -> MsgPackValue? {
            var values: [MsgPackValue] = []
            values.reserveCapacity(min(count, 1024))
            for _ in 0 ..< count {
                guard let value = self.readValue() else {
                    return nil
                }
                values.append(value)
            }
            return .array(values)
        }

        mutating func readMap(count: Int) -> MsgPackValue? {
            var entries: [(key: MsgPackValue, value: MsgPackValue)] = []
            entries.reserveCapacity(min(count, 1024))
            for _ in 0 ..< count {
                guard let key = self.readValue(), let value = self.readValue() else {
                    return nil
                }
                entries.append((key, value))
            }
            return .map(entries)
        }
    }
}
