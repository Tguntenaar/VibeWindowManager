//
//  VibeSTTService.swift
//  VibeWindowManager
//
//  Placeholder for on-Mac speech-to-text. Wire whisper / faster-whisper later.
//

import Foundation

@MainActor
final class VibeSTTService {
    private var pcmBuffer = Data()

    /// `nil` while more chunks are expected (`end` is false). On `end`, returns a final `(text, error)`.
    func process(base64: String, end: Bool) -> (String, String?)? {
        if !base64.isEmpty, let d = Data(base64Encoded: base64) {
            pcmBuffer.append(d)
        }
        if !end { return nil }
        defer { pcmBuffer.removeAll(keepingCapacity: true) }
        if pcmBuffer.isEmpty { return ("", nil) }
        // Stub: no model installed.
        return ("", "STT not configured (stub). Install a local whisper binary in a later version.")
    }
}
