import AVFoundation
import Foundation

/// Explicitly opt-in local audio capture for comparing ASR engines against the
/// same utterance. Disabled by default. Files never leave Application Support
/// and are included in the existing confirmed "Pour it away" wipe action.
enum ASRBenchmarkCapture {
    static let enabledKey = "asrBenchmarkCaptureEnabled"
    private static let queue = DispatchQueue(label: "com.llatser.listen.asr-benchmark", qos: .utility)
    private static let sampleRate = 16_000.0

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beers", isDirectory: true)
            .appendingPathComponent("ASR Benchmarks", isDirectory: true)
    }

    static func recordIfEnabled(
        audio: [Float],
        rawTranscript: String,
        engine: DictationEngine,
        languageMode: ASRLanguageMode
    ) {
        guard UserDefaults.standard.bool(forKey: enabledKey), !audio.isEmpty else { return }

        queue.async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let stem = "pour-\(stamp)-\(UUID().uuidString.prefix(8))"
                let audioURL = directory.appendingPathComponent("\(stem).wav")
                try writeWAV(audio, to: audioURL)
                try appendManifest(
                    file: audioURL.lastPathComponent,
                    rawTranscript: rawTranscript,
                    engine: engine,
                    languageMode: languageMode
                )
                llog("ASRBenchmark: captured local sample '\(audioURL.lastPathComponent)'")
            } catch {
                llog("ASRBenchmark: capture failed (\(error.localizedDescription))")
            }
        }
    }

    @discardableResult
    static func wipe() -> Int {
        queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: directory.path) else { return 0 }
            let count = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count) ?? 0
            try? fm.removeItem(at: directory)
            return count
        }
    }

    static func flush() {
        queue.sync {}
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let destination = buffer.floatChannelData?[0] else {
            throw BenchmarkError.invalidAudio
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: samples.count)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func appendManifest(
        file: String,
        rawTranscript: String,
        engine: DictationEngine,
        languageMode: ASRLanguageMode
    ) throws {
        let record: [String: Any] = [
            "file": file,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "productionEngine": engine.rawValue,
            "productionLanguage": languageMode.rawValue,
            "productionTranscript": rawTranscript,
            "gold": "",
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)

        let manifest = directory.appendingPathComponent("manifest.jsonl")
        if !FileManager.default.fileExists(atPath: manifest.path) {
            FileManager.default.createFile(atPath: manifest.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    enum BenchmarkError: LocalizedError {
        case invalidAudio

        var errorDescription: String? { "Benchmark audio could not be prepared." }
    }
}

/// Batch runner used by `--beers-asr-benchmark <directory>`. It compares v3
/// auto-detection, v3 with an English hint, and v2 English against identical
/// locally captured WAVs, then writes results.jsonl beside the manifest.
enum ASRBenchmarkRunner {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--beers-asr-benchmark")
    }

    @MainActor
    static func runIfRequested() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--beers-asr-benchmark"),
              CommandLine.arguments.count > flag + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)

        Task {
            do {
                let output = try await run(directory: directory)
                print("ASR benchmark complete: \(output.path)")
                exit(0)
            } catch {
                let message = "ASR benchmark failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
        }
    }

    private struct Sample {
        let file: String
        let audio: [Float]
        let productionTranscript: String
        let gold: String
    }

    private struct Result {
        let sample: Sample
        var v3Auto = ""
        var v3AutoMs = 0.0
        var v3English = ""
        var v3EnglishMs = 0.0
        var v2English = ""
        var v2EnglishMs = 0.0
    }

    private static func run(directory: URL) async throws -> URL {
        var results = try loadSamples(from: directory).map { Result(sample: $0) }
        guard !results.isEmpty else { throw RunnerError.noSamples }

        let engine = TranscriptionEngine()
        try await engine.load(.parakeetV3) { progress, message in
            if progress >= 1 { llog("ASRBenchmark: \(message)") }
        }
        for index in results.indices {
            (results[index].v3Auto, results[index].v3AutoMs) = try await measuredTranscription(
                engine: engine,
                audio: results[index].sample.audio,
                languageMode: .automatic
            )
            (results[index].v3English, results[index].v3EnglishMs) = try await measuredTranscription(
                engine: engine,
                audio: results[index].sample.audio,
                languageMode: .english
            )
        }

        try await engine.load(.parakeetV2) { progress, message in
            if progress >= 1 { llog("ASRBenchmark: \(message)") }
        }
        for index in results.indices {
            (results[index].v2English, results[index].v2EnglishMs) = try await measuredTranscription(
                engine: engine,
                audio: results[index].sample.audio,
                languageMode: .english
            )
        }

        let output = directory.appendingPathComponent("results.jsonl")
        var body = Data()
        for result in results {
            let row: [String: Any] = [
                "file": result.sample.file,
                "productionTranscript": result.sample.productionTranscript,
                "gold": result.sample.gold,
                "v3Auto": result.v3Auto,
                "v3AutoMs": result.v3AutoMs,
                "v3English": result.v3English,
                "v3EnglishMs": result.v3EnglishMs,
                "v2English": result.v2English,
                "v2EnglishMs": result.v2EnglishMs,
            ]
            body.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            body.append(0x0A)
        }
        try body.write(to: output, options: .atomic)
        return output
    }

    private static func measuredTranscription(
        engine: TranscriptionEngine,
        audio: [Float],
        languageMode: ASRLanguageMode
    ) async throws -> (String, Double) {
        let start = Date()
        let text = try await engine.transcribe(audio, languageMode: languageMode)
        return (text, Date().timeIntervalSince(start) * 1_000)
    }

    private static func loadSamples(from directory: URL) throws -> [Sample] {
        let manifest = directory.appendingPathComponent("manifest.jsonl")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            throw RunnerError.missingManifest
        }

        var samples: [Sample] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(200) {
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let file = row["file"] as? String,
                  file == URL(fileURLWithPath: file).lastPathComponent,
                  file.lowercased().hasSuffix(".wav") else { continue }
            let audio = try loadWAV(directory.appendingPathComponent(file))
            samples.append(Sample(
                file: file,
                audio: audio,
                productionTranscript: row["productionTranscript"] as? String ?? "",
                gold: row["gold"] as? String ?? ""
            ))
        }
        return samples
    }

    private static func loadWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 1,
              abs(format.sampleRate - 16_000) < 1,
              file.length <= 16_000 * 300 else {
            throw RunnerError.unsupportedAudio(url.lastPathComponent)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw RunnerError.unsupportedAudio(url.lastPathComponent) }
        try file.read(into: buffer)
        guard let source = buffer.floatChannelData?[0] else {
            throw RunnerError.unsupportedAudio(url.lastPathComponent)
        }
        return Array(UnsafeBufferPointer(start: source, count: Int(buffer.frameLength)))
    }

    enum RunnerError: LocalizedError {
        case missingManifest
        case noSamples
        case unsupportedAudio(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest: return "manifest.jsonl was not found in the benchmark directory."
            case .noSamples: return "The benchmark manifest contains no readable samples."
            case .unsupportedAudio(let file): return "\(file) is not a 16 kHz mono benchmark WAV."
            }
        }
    }
}
