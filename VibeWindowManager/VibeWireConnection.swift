//
//  VibeWireConnection.swift
//  VibeWindowManager
//
//  One NWConnection: HTTP → WebSocket upgrade, then text frames.
//

import Foundation
import Network

final class VibeWireConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var readBuffer = Data()
    private var webSocketReady = false
    private var clientClosed = false
    private var finished = false
    private let onText: (String) -> Void
    private let onClosed: () -> Void
    private let queue: DispatchQueue

    init(
        _ connection: NWConnection,
        label: String,
        onText: @escaping (String) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.connection = connection
        self.onText = onText
        self.onClosed = onClosed
        self.queue = DispatchQueue(label: label)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.finish() }
            case .ready:
                self.queue.async { self.receiveLoop() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            self.queue.async {
                if let d = data, !d.isEmpty { self.readBuffer.append(d) }
                self.processBuffer()
                if isComplete { self.finish(); return }
                if !self.finished { self.receiveLoop() }
            }
        }
    }

    private func processBuffer() {
        if !webSocketReady {
            if let req = HTTPRequestParser.firstRequest(from: &readBuffer) {
                guard req.method == "GET",
                    req.path.hasPrefix("/bridge"),
                    let key = req.headerFields["sec-websocket-key"]
                else {
                    self.connection.cancel()
                    finish()
                    return
                }
                let accept = makeAcceptKey(from: key)
                let res =
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                if let d = res.data(using: .utf8) {
                    self.connection.send(content: d, isComplete: false, completion: .idempotent)
                }
                webSocketReady = true
            }
        }
        if webSocketReady {
            var texts: [String] = []
            VibeWebSocketFraming.readClientFrames(from: &readBuffer, outStrings: &texts, clientClosed: &clientClosed)
            for t in texts {
                DispatchQueue.main.async { [onText] in onText(t) }
            }
            if clientClosed { DispatchQueue.main.async { [weak self] in self?.finish() } }
        }
    }

    private func makeAcceptKey(from secKey: String) -> String {
        let s = secKey + VibeWebSocketFraming.rfcKeySuffix
        let d = Data(s.utf8)
        let h = SHA1Hash.data(d)
        return h.base64EncodedString()
    }

    func sendJSONText(_ text: String) {
        let framed = VibeWebSocketFraming.encodeTextFrame(text)
        connection.send(content: framed, isComplete: true, completion: .idempotent)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        DispatchQueue.main.async { [onClosed] in onClosed() }
    }

    func cancel() {
        finish()
    }
}
