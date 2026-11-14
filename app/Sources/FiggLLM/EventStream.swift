import Foundation

/// One message from an `application/vnd.amazon.eventstream` response.
struct EventStreamMessage: Equatable {
    var headers: [String: String]
    var payload: Data
}

/// Incremental decoder for the AWS event-stream framing used by Bedrock
/// ConverseStream. Frame layout (big-endian):
///   total length (4) | headers length (4) | prelude CRC (4) | headers | payload | message CRC (4)
/// CRCs are not checked; TLS already guarantees integrity.
struct EventStreamDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or nil if more bytes are needed.
    mutating func next() throws -> EventStreamMessage? {
        guard buffer.count >= 12 else { return nil }
        let start = buffer.startIndex
        let total = Int(readUInt32(at: start))
        let headersLength = Int(readUInt32(at: start + 4))
        guard total >= 16, headersLength <= total - 16 else { throw LLMError.other("Malformed Bedrock stream frame") }
        guard buffer.count >= total else { return nil }

        let headersStart = start + 12
        let payloadStart = headersStart + headersLength
        let payloadEnd = start + total - 4
        let headers = try parseHeaders(buffer[headersStart..<payloadStart])
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer = Data(buffer[(start + total)...])
        return EventStreamMessage(headers: headers, payload: payload)
    }

    private func readUInt32(at i: Data.Index) -> UInt32 {
        buffer[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Keeps string headers (all Bedrock uses); skips the other value types.
    private func parseHeaders(_ data: Data) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = data.startIndex
        func take(_ n: Int) throws -> Data {
            guard data.distance(from: i, to: data.endIndex) >= n else { throw LLMError.other("Malformed Bedrock stream header") }
            defer { i += n }
            return data[i..<i + n]
        }
        func uint16() throws -> Int { try take(2).reduce(0) { $0 << 8 | Int($1) } }

        while i < data.endIndex {
            let nameLength = Int(try take(1).first!)
            let name = String(decoding: try take(nameLength), as: UTF8.self)
            let type = try take(1).first!
            switch type {
            case 0, 1: break                       // bool true / false
            case 2: _ = try take(1)                // byte
            case 3: _ = try take(2)                // short
            case 4: _ = try take(4)                // int
            case 5, 8: _ = try take(8)             // long, timestamp
            case 6: _ = try take(try uint16())     // bytes
            case 7: out[name] = String(decoding: try take(try uint16()), as: UTF8.self)
            case 9: _ = try take(16)               // uuid
            default: throw LLMError.other("Unknown Bedrock stream header type \(type)")
            }
        }
        return out
    }
}
