//
//  VibeSTTService.swift
//  VibeWindowManager
//
//  Runs a local speech-to-text binary (whisper.cpp) on accumulated PCM. Configure paths in
//  the Mac app (bridge section) and UserDefaults.
//

import Foundation

enum VibeSTTUserDefaults: Sendable {
    nonisolated static let binaryPath = "vibeWhisperBinaryPath"
    nonisolated static let modelPath = "vibeWhisperModelPath"
    nonisolated static let language = "vibeWhisperLanguage" // e.g. "en"; empty = auto
    /// `pip install -U openai-whisper` → `which whisper` (uses model **names** like `base`, not a `.bin` file).
    nonisolated static let useOpenAIPip = "vibeWhisperOpenAIPip"
}

/// PCM → WAV header + **whisper.cpp** or **OpenAI Whisper (pip)** `Process` (off the main thread).
enum VibeSTTService: Sendable {
    /// - Returns: `(transcript, errorMessage)`. Empty transcript is valid when the model returns nothing.
    static func transcribePcmS16leMono16k(pcm: Data) async -> (String, String?) {
        var bin = UserDefaults.standard.string(forKey: VibeSTTUserDefaults.binaryPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let useOpenAIPip = (UserDefaults.standard.object(forKey: VibeSTTUserDefaults.useOpenAIPip) as? Bool)
            ?? true
        var model = UserDefaults.standard.string(forKey: VibeSTTUserDefaults.modelPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if useOpenAIPip, model.isEmpty {
            model = "base"
        }
        if bin.isEmpty, useOpenAIPip, let r = openAIWhisperBinaryFromCommonInstalls() {
            bin = r
        }
        if bin.isEmpty {
            return (
                "",
                "STT: set the Whisper binary path in the Mac app, or `pip install openai-whisper` and ensure `~/.pyenv/shims/whisper` (or Homebrew) exists. Run `which whisper` in Terminal if unsure."
            )
        }
        if model.isEmpty {
            return (
                "",
                "STT: set the model file path (e.g. …/ggml-base.en.bin) for whisper.cpp, or turn on OpenAI Whisper (pip) and use a name like base."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            return ("", "STT: binary is not executable or missing at \(bin)")
        }
        if !useOpenAIPip {
            guard FileManager.default.fileExists(atPath: model) else {
                return ("", "STT: model not found at \(model)")
            }
        }
        if pcm.isEmpty {
            return ("", "No audio captured.")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<(String, String?), Never>) in
            Task.detached {
                do {
                    let (text, err): (String, String?)
                    if useOpenAIPip {
                        (text, err) = try runOpenAIWhisperSync(binary: bin, modelName: model, pcm: pcm)
                    } else {
                        (text, err) = try runWhisperCppSync(binary: bin, modelPath: model, pcm: pcm)
                    }
                    cont.resume(returning: (text, err))
                } catch {
                    cont.resume(returning: ("", error.localizedDescription))
                }
            }
        }
    }

    /// When the user has not set a path, look for a typical `pip` / pyenv / Homebrew `whisper` binary.
    private static func openAIWhisperBinaryFromCommonInstalls() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cands: [String] = [
            "\(home)/.pyenv/shims/whisper",
            "\(home)/.local/bin/whisper",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper",
        ]
        for c in cands {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    // MARK: - OpenAI Whisper `pip install openai-whisper` (sync, background)

    private nonisolated static func runOpenAIWhisperSync(
        binary: String,
        modelName: String,
        pcm: Data
    ) throws -> (String, String?) {
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let jobDir = tmp.appendingPathComponent("vibe_openai_\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let wavURL = jobDir.appendingPathComponent("in.wav")
        let wavData = makeWavData(pcmS16le: pcm, sampleRate: 16_000, channels: 1)
        try wavData.write(to: wavURL, options: .atomic)

        let lang = UserDefaults.standard.string(forKey: VibeSTTUserDefaults.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var args: [String] = [
            wavURL.path,
            "--model", modelName,
            "--output_dir", jobDir.path,
            "--output_format", "txt",
        ]
        if !lang.isEmpty {
            args += ["--language", lang]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.currentDirectoryURL = jobDir

        try p.run()
        p.waitUntilExit()

        let txtPath = jobDir.appendingPathComponent("in.txt")
        defer { try? FileManager.default.removeItem(at: jobDir) }

        guard p.terminationStatus == 0 else {
            let errData = (p.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if errStr.isEmpty {
                return ("", "STT: whisper (OpenAI) exited with status \(p.terminationStatus).")
            }
            return ("", "STT: \(errStr)")
        }

        if FileManager.default.fileExists(atPath: txtPath.path) {
            let t = (try? String(contentsOf: txtPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (t, t.isEmpty ? "STT: empty transcript." : nil)
        }
        return ("", "STT: expected text at \(txtPath.path) but it was not created.")
    }

    // MARK: - whisper.cpp (sync, background)

    private nonisolated static func runWhisperCppSync(
        binary: String,
        modelPath: String,
        pcm: Data
    ) throws -> (String, String?) {
        let model = modelPath
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let wavURL = tmp.appendingPathComponent("vibewhisper_\(id).wav")
        let outBase = tmp.appendingPathComponent("vibewhisper_\(id)_out")
        let wavData = makeWavData(pcmS16le: pcm, sampleRate: 16_000, channels: 1)
        try wavData.write(to: wavURL, options: .atomic)

        let lang = UserDefaults.standard.string(forKey: VibeSTTUserDefaults.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var args: [String] = [
            "-m", model,
            "-f", wavURL.path,
            "-otxt",
            "-of", outBase.path,
        ]
        if !lang.isEmpty {
            args += ["-l", lang]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.currentDirectoryURL = tmp

        try p.run()
        p.waitUntilExit()

        try? FileManager.default.removeItem(at: wavURL)

        guard p.terminationStatus == 0 else {
            let errData = (p.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if errStr.isEmpty {
                return ("", "STT: whisper.cpp exited with status \(p.terminationStatus).")
            }
            return ("", "STT: \(errStr)")
        }

        let txtPath = outBase.appendingPathExtension("txt")
        if FileManager.default.fileExists(atPath: txtPath.path) {
            let t = (try? String(contentsOf: txtPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: txtPath)
            return (t, t.isEmpty ? "STT: empty transcript." : nil)
        }

        // Some builds use a different naming scheme — try a glob near temp.
        return ("", "STT: expected text output at \(txtPath.path) but it was not created.")
    }

    /// Linear PCM 16-bit mono → minimal RIFF WAVE
    private nonisolated static func makeWavData(
        pcmS16le: Data,
        sampleRate: Double,
        channels: UInt16
    ) -> Data {
        var d = Data()
        let dataSize = UInt32(pcmS16le.count)
        var sampleRateU = UInt32(sampleRate)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        var byteRate = sampleRateU * UInt32(blockAlign)
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        var chunkSize: UInt32 = 36 + dataSize
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1 // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels
        header.append(Data(bytes: &ch, count: 2))
        header.append(Data(bytes: &sampleRateU, count: 4))
        header.append(Data(bytes: &byteRate, count: 4))
        var blockAlign2 = blockAlign
        header.append(Data(bytes: &blockAlign2, count: 2))
        var bits = bitsPerSample
        header.append(Data(bytes: &bits, count: 2))
        header.append("data".data(using: .ascii)!)
        var dataSize2 = dataSize
        header.append(Data(bytes: &dataSize2, count: 4))
        d.append(header)
        d.append(pcmS16le)
        return d
    }
}
