//
//  VibeAgentDebugLog.swift
//  VibeWindowManager
//
//  Ephemeral session logging for coordinate debugging (NDJSON, session 0411ea).
//

import Foundation

enum VibeAgentDebugLog {
    static let path = "/Users/thomasguntenaar/Desktop/code.nosync/guntech/pixeloffice/.cursor/debug-0411ea.log"
    static let sessionId = "0411ea"

    static func append(hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
        // #region agent log
        let o: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data
        ]
        guard let j = try? JSONSerialization.data(withJSONObject: o, options: []),
            let line = String(data: j, encoding: .utf8)
        else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let u = URL(fileURLWithPath: path)
        guard let f = try? FileHandle(forWritingTo: u) else { return }
        defer { try? f.close() }
        f.seekToEndOfFile()
        f.write((line + "\n").data(using: .utf8) ?? Data())
        // #endregion
    }
}
