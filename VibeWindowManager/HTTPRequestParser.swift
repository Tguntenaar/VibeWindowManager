//
//  HTTPRequestParser.swift
//  VibeWindowManager
//
//  Minimal first-line + headers for WebSocket upgrade.
//

import Foundation

struct ParsedHeadRequest: Sendable {
    let method: String
    let path: String
    let headerFields: [String: String] // lowercased keys
}

enum HTTPRequestParser {
    static func firstRequest(from buffer: inout Data) -> ParsedHeadRequest? {
        let needle = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: needle) else { return nil }
        let head = buffer.prefix(r.lowerBound)
        buffer.removeSubrange(0..<r.upperBound)
        guard let s = String(data: head, encoding: .utf8) else { return nil }
        var lines = s.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        lines.removeFirst()
        for line in lines {
            if let c = line.firstIndex(of: ":") {
                let k = String(line[..<c]).lowercased().trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return ParsedHeadRequest(method: method, path: path, headerFields: headers)
    }
}
