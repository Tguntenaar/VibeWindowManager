//
//  BridgeProtocolModels.swift
//  VibeWindowManager
//
//  JSON DTOs for the LAN bridge (see docs/PROTOCOL.md).
//

import Foundation

// MARK: - Envelope

enum BridgeMessageType: String, Codable {
    case serverHello
    case clientHello
    case ping
    case pong
    case layout
    case select
    case selectNext
    case pasteText
    case transcribe
    case transcribeResult
    case error
    case setWindowRect
}

// MARK: - Outgoing (server)

struct BridgeServerHello: Codable {
    var type: String = BridgeMessageType.serverHello.rawValue
    var version: Int
    var port: UInt16
}

struct BridgePong: Codable {
    var type: String = BridgeMessageType.pong.rawValue
    var t: Int64
}

struct BridgeLayoutMessage: Codable, Equatable {
    var type: String = BridgeMessageType.layout.rawValue
    var seq: UInt64
    var appName: String?
    var bundleId: String?
    var reference: BridgeRect
    var windows: [BridgeWindow]
    var selectedId: String?
}

struct BridgeRect: Codable, Equatable {
    var x, y, width, height: Double
}

struct BridgeWindow: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var zIndex: Int
    var rect: BridgeRect
}

struct BridgeErrorMessage: Codable {
    var type: String = BridgeMessageType.error.rawValue
    var message: String
}

struct BridgeTranscribeResult: Codable {
    var type: String = BridgeMessageType.transcribeResult.rawValue
    var text: String
    var error: String?
}

// MARK: - Incoming (client)

struct BridgeClientHello: Codable {
    var type: String
    var version: Int
    var client: String?
}

struct BridgePing: Codable {
    var type: String
    var t: Int64
}

struct BridgeSelect: Codable {
    var type: String
    var windowId: String
}

struct BridgeSelectNext: Codable {
    var type: String
}

struct BridgeSetWindowRect: Codable {
    var type: String
    var windowId: String
    var rect: BridgeRect
}

struct BridgePasteText: Codable {
    var type: String
    var text: String
}

struct BridgeTranscribe: Codable {
    var type: String
    var format: String
    var base64: String
    var end: Bool
}

// MARK: - Decode helper

enum BridgeJSONDecodeError: Error {
    case unknownType(String)
}

func decodeClientMessage(from string: String) throws -> Any {
    let data = Data(string.utf8)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let type = (obj?["type"] as? String) ?? ""
    let decoder = JSONDecoder()
    switch type {
    case BridgeMessageType.clientHello.rawValue:
        return try decoder.decode(BridgeClientHello.self, from: data)
    case BridgeMessageType.ping.rawValue:
        return try decoder.decode(BridgePing.self, from: data)
    case BridgeMessageType.select.rawValue:
        return try decoder.decode(BridgeSelect.self, from: data)
    case BridgeMessageType.selectNext.rawValue:
        return try decoder.decode(BridgeSelectNext.self, from: data)
    case BridgeMessageType.pasteText.rawValue:
        return try decoder.decode(BridgePasteText.self, from: data)
    case BridgeMessageType.transcribe.rawValue:
        return try decoder.decode(BridgeTranscribe.self, from: data)
    case BridgeMessageType.setWindowRect.rawValue:
        return try decoder.decode(BridgeSetWindowRect.self, from: data)
    default:
        throw BridgeJSONDecodeError.unknownType(type)
    }
}
