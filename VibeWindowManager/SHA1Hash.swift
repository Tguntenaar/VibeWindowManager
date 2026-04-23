//
//  SHA1Hash.swift
//  VibeWindowManager
//
//  SHA-1 for WebSocket `Sec-WebSocket-Accept` (RFC 6455).
//

import CommonCrypto
import Foundation

enum SHA1Hash {
    static func data(_ input: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        input.withUnsafeBytes { buf in
            _ = CC_SHA1(buf.baseAddress, CC_LONG(input.count), &out)
        }
        return Data(out)
    }
}
