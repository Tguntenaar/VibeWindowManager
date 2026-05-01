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
    case transcribeLive
    case transcribeResult
    case error
    case setWindowRect
    case requestTmuxPane
    case tmuxPane
    case mirrorAppList
    case setMirrorAppQuery
    case windowStream
    case setWindowStreamEnabled
    case windowStreamClick
    case openCalibrationTarget
    case closeCalibrationTarget
    case calibrationTarget
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
    /// Desktop-wide coordinate space (union of every display's layout frame in AppKit global coords).
    /// All `windows[].rect` and `screens[]` entries are normalized 0..1 top-left relative to this.
    var reference: BridgeRect
    /// Per-physical-display rects normalized against `reference`. Clients render one outline per entry.
    var screens: [BridgeRect] = []
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

struct BridgeTmuxPaneMessage: Codable {
    var type: String = BridgeMessageType.tmuxPane.rawValue
    var seq: UInt64
    var text: String
    var error: String?
    var truncated: Bool
}

struct BridgeMirrorAppEntry: Codable, Equatable {
    var name: String
    var bundleId: String
    /// Optional 48×48 PNG, base64 (no data: prefix), for the iOS grid.
    var iconPNGBase64: String?
}

struct BridgeMirrorAppListMessage: Codable, Equatable {
    var type: String = BridgeMessageType.mirrorAppList.rawValue
    var seq: UInt64
    var apps: [BridgeMirrorAppEntry]
}

struct BridgeWindowStreamMessage: Codable, Equatable {
    var type: String = BridgeMessageType.windowStream.rawValue
    var seq: UInt64
    var windowId: String
    /// Wire format, e.g. `jpeg` (from `screencapture` + optional downscale on the Mac).
    var format: String
    var base64: String?
    var error: String?
}

/// Server → client: tap targets for the white calibration window; user taps the dot in the live tile `sampleCount` times.
struct BridgeCalibrationTargetMessage: Codable, Equatable {
    var type: String = BridgeMessageType.calibrationTarget.rawValue
    var windowId: String
    /// Expected hit (0…1, top-left of bitmap) for the target dot, matching `windowStreamClick` convention.
    var expectNx: Double
    var expectNy: Double
    var sampleCount: Int
    /// 0…`sampleCount-1` — which of the random placements is currently shown; dot moves after each iPad sample.
    var sampleIndex: Int
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

/// iOS SFSpeech partials while holding the mic: server replaces the previous in-place (backspace + paste) for live typing.
struct BridgeTranscribeLive: Codable {
    var type: String
    var text: String
}

struct BridgeRequestTmuxPane: Codable {
    var type: String
    var lines: Int?
}

struct BridgeSetMirrorAppQuery: Codable {
    var type: String = BridgeMessageType.setMirrorAppQuery.rawValue
    var bundleId: String
}

struct BridgeSetWindowStreamEnabled: Codable {
    var type: String = BridgeMessageType.setWindowStreamEnabled.rawValue
    var enabled: Bool
}

/// Client → server: user tapped the live window JPEG. `nx`/`ny` are 0…1, **top-left** origin, within the
/// captured image bitmap (see iOS: inverse of `scaleAspectFill` so clicks match pixels).
struct BridgeWindowStreamClick: Codable {
    var type: String = BridgeMessageType.windowStreamClick.rawValue
    var windowId: String
    var nx: Double
    var ny: Double
}

struct BridgeClientOpenCalibration: Codable {
    var type: String = BridgeMessageType.openCalibrationTarget.rawValue
}

struct BridgeClientCloseCalibration: Codable {
    var type: String = BridgeMessageType.closeCalibrationTarget.rawValue
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
    case BridgeMessageType.transcribeLive.rawValue:
        return try decoder.decode(BridgeTranscribeLive.self, from: data)
    case BridgeMessageType.setWindowRect.rawValue:
        return try decoder.decode(BridgeSetWindowRect.self, from: data)
    case BridgeMessageType.requestTmuxPane.rawValue:
        return try decoder.decode(BridgeRequestTmuxPane.self, from: data)
    case BridgeMessageType.setMirrorAppQuery.rawValue:
        return try decoder.decode(BridgeSetMirrorAppQuery.self, from: data)
    case BridgeMessageType.setWindowStreamEnabled.rawValue:
        return try decoder.decode(BridgeSetWindowStreamEnabled.self, from: data)
    case BridgeMessageType.windowStreamClick.rawValue:
        return try decoder.decode(BridgeWindowStreamClick.self, from: data)
    case BridgeMessageType.openCalibrationTarget.rawValue:
        return try decoder.decode(BridgeClientOpenCalibration.self, from: data)
    case BridgeMessageType.closeCalibrationTarget.rawValue:
        return try decoder.decode(BridgeClientCloseCalibration.self, from: data)
    default:
        throw BridgeJSONDecodeError.unknownType(type)
    }
}
