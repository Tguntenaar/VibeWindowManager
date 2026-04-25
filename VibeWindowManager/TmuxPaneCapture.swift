//
//  TmuxPaneCapture.swift
//  VibeWindowManager
//
//  Runs `tmux capture-pane` off the main thread; applies line/byte limits for the bridge.
//

import Foundation

enum TmuxPaneCapture {
    static let defaultLineLimit = 400
    static let maxLineLimit = 20_000
    static let maxOutputUTF8Bytes = 256 * 1024

    /// Returns tail `lineLimit` lines (by splitting on `\n`), then applies a UTF-8 byte cap from the **end** (newest output).
    static func applyLineAndByteLimits(
        _ raw: String,
        lineLimit: Int,
        maxBytes: Int = maxOutputUTF8Bytes
    ) -> (text: String, truncated: Bool) {
        let clampedLines = min(max(lineLimit, 1), maxLineLimit)
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var lineTruncated = false
        let lineChunk: [Substring]
        if parts.count > clampedLines {
            lineChunk = Array(parts.suffix(clampedLines))
            lineTruncated = true
        } else {
            lineChunk = parts
        }
        var s = lineChunk.joined(separator: "\n")
        let (byteCapped, byteTruncated) = utf8ByteSuffix(s, maxBytes: maxBytes)
        s = byteCapped
        return (s, lineTruncated || byteTruncated)
    }

    /// Keep at most `maxBytes` UTF-8 code units, preferring the **suffix** of `s` (recent terminal output).
    static func utf8ByteSuffix(_ s: String, maxBytes: Int) -> (String, Bool) {
        guard maxBytes > 0 else { return ("", !s.isEmpty) }
        let data = Data(s.utf8)
        if data.count <= maxBytes { return (s, false) }
        var tail = Data(data.suffix(maxBytes))
        // If we cut mid–UTF-8 char, drop leading continuation bytes (10xxxxxx).
        var i = 0
        while i < tail.count, (tail[i] & 0xC0) == 0x80 { i += 1 }
        if i > 0 { tail = Data(tail[i...]) }
        let out = String(data: tail, encoding: .utf8) ?? ""
        return (out, true)
    }

    /// `target` is a tmux `session:window.pane` string (e.g. `0:0.0` or `mydev:bash.0`).
    static func capturePane(
        target: String,
        lineLimit: Int,
        environmentLaunchPath: String = "/usr/bin/env"
    ) async -> (text: String, error: String?, truncated: Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = runProcess(
                    lineLimit: lineLimit,
                    launchPath: environmentLaunchPath,
                    arguments: [
                        "tmux", "capture-pane", "-p", "-t", target, "-S", "-", "-E", "-"
                    ]
                )
                cont.resume(returning: out)
            }
        }
    }

    private static func runProcess(
        lineLimit: Int,
        launchPath: String,
        arguments: [String]
    ) -> (text: String, error: String?, truncated: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = nil
        do {
            try p.run()
        } catch {
            return ("", error.localizedDescription, false)
        }
        p.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 {
            let msg: String
            if !errStr.isEmpty {
                msg = "tmux: \(errStr)"
            } else if let raw = String(data: outData, encoding: .utf8), !raw.isEmpty {
                msg = "tmux (exit \(p.terminationStatus)): \(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else {
                msg = "tmux exited with status \(p.terminationStatus)"
            }
            return ("", msg, false)
        }
        let raw = String(data: outData, encoding: .utf8) ?? ""
        let limited = applyLineAndByteLimits(raw, lineLimit: lineLimit)
        return (limited.text, nil, limited.truncated)
    }
}
