//
//  AgentDebugLog.swift
//  VibeWindowManager
//
//  Session debug: NDJSON to Cursor log file (macOS only).
//

import Foundation

enum AgentDebugLog {
    private static let logPath = "/Users/thomasguntenaar/Desktop/code.nosync/guntech/pixeloffice/.cursor/debug-155edc.log"

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let payload: [String: Any] = [
            "sessionId": "155edc",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        guard var line = String(data: json, encoding: .utf8) else { return }
        line += "\n"
        guard let d = line.data(using: .utf8) else { return }
        let u = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            if let h = try? FileHandle(forWritingTo: u) {
                h.seekToEndOfFile()
                h.write(d)
                try? h.close()
            }
        } else {
            try? d.write(to: u, options: .atomic)
        }
    }
}
