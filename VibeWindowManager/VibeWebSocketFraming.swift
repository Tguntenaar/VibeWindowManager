//
//  VibeWebSocketFraming.swift
//  VibeWindowManager
//
//  RFC 6455 text frames (unmasked from server, masked from client).
//

import Foundation

enum VibeWebSocketFraming {
    private static let opText: UInt8 = 0x01
    private static let opClose: UInt8 = 0x08
    private static let finBit: UInt8 = 0x80

    static let rfcKeySuffix = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Unmasked text frame (server → client).
    static func encodeTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        return encode(fin: true, opcode: opText, mask: false, payload: payload)
    }

    static func encodeClose() -> Data {
        encode(fin: true, opcode: opClose, mask: false, payload: Data())
    }

    private static func encode(fin: Bool, opcode: UInt8, mask: Bool, payload: Data) -> Data {
        var out = Data()
        var b0: UInt8 = opcode
        if fin { b0 |= finBit }
        out.append(b0)
        let len = payload.count
        var maskByte: UInt8 = 0
        if mask { maskByte |= 0x80 }
        if len < 126 {
            out.append(maskByte | UInt8(len))
        } else if len < 65_536 {
            out.append(maskByte | 126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(maskByte | 127)
            for s in (0..<8).reversed() {
                out.append(UInt8((Int64(len) >> (s * 8)) & 0xFF))
            }
        }
        if mask {
            let k = (0..<4).map { _ in UInt8.random(in: 0...255) }
            for b in k { out.append(b) }
            for i in payload.indices { out.append(payload[i] ^ k[i % 4]) }
        } else {
            out.append(payload)
        }
        return out
    }

    /// Removes one or more complete client frames. Appends `text` payloads to `outStrings`. Sets `clientClosed` on close.
    static func readClientFrames(
        from buffer: inout Data,
        outStrings: inout [String],
        clientClosed: inout Bool
    ) {
        while !buffer.isEmpty {
            let b = [UInt8](buffer)
            if b.count < 2 { return }
            let opcode = b[0] & 0x0F
            let b1 = b[1]
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var i = 2
            if payloadLen == 126 {
                guard b.count >= 4 else { return }
                payloadLen = (Int(b[2]) << 8) | Int(b[3])
                i = 4
            } else if payloadLen == 127 {
                guard b.count >= 10 else { return }
                var l = 0
                for j in 0..<8 { l = (l << 8) | Int(b[2 + j]) }
                payloadLen = l
                i = 10
            }
            let maskKeyLen = masked ? 4 : 0
            let totalFrame = i + maskKeyLen + payloadLen
            guard b.count >= totalFrame else { return }
            let maskStart = i
            let pStart = i + maskKeyLen
            var payload = Data(b[pStart..<pStart + payloadLen])
            if masked {
                let key = (0..<4).map { b[maskStart + $0] }
                for j in payload.indices { payload[j] ^= key[j % 4] }
            }
            buffer.removeFirst(totalFrame)
            if opcode == opClose { clientClosed = true; return }
            if opcode == opText, let t = String(data: payload, encoding: .utf8) { outStrings.append(t) }
        }
    }
}
