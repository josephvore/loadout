// Parakeet.swift — second-pass ASR for hs-dictate.
//
// Apple's SpeechTranscriber streams live partials for the overlay, but its
// final transcripts carry the mishears the user actually notices. Parakeet
// TDT 0.6b (FluidAudio CoreML, Apple Neural Engine) re-transcribes the take's
// buffered audio on stop — ~0.2s for a typical take at roughly half Apple's
// word error rate — and owns the FINAL transcript whenever it is ready and
// succeeds. Apple's final text remains the fallback, so a missing model or a
// slow first load never blocks a paste.
//
// Audio: the mic tap hands every buffer to `append`, which resamples to the
// 16 kHz mono Float32 Parakeet expects and accumulates it for the current
// take (64 KB/s — minutes of speech are fine).

import AVFoundation
import Foundation
import FluidAudio

final class ParakeetPass: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var converter: AVAudioConverter?
    private var asr: AsrManager?
    private var decoderLayers = 2

    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    // Parakeet rejects takes shorter than 300 ms (4,800 samples @ 16 kHz).
    static let minimumSamples = 4_800

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return asr != nil
    }

    // NSLock must not be taken directly inside async functions; these
    // synchronous helpers keep every critical section out of async frames.
    private func installManager(_ manager: AsrManager, layers: Int) {
        lock.lock(); defer { lock.unlock() }
        asr = manager
        decoderLayers = layers
    }

    private func managerSnapshot() -> (AsrManager?, Int) {
        lock.lock(); defer { lock.unlock() }
        return (asr, decoderLayers)
    }

    // Download (first run only, ~480 MB) and load the CoreML models, then run
    // a silent warmup so the first real take doesn't pay ANE instantiation.
    // Runs off the ready path; the daemon serves Apple finals until this
    // lands. Emits diagnostics either way so the Lua side can log it.
    func prepare(version: AsrModelVersion) async {
        let started = Date()
        do {
            let cacheDir = AsrModels.defaultCacheDirectory(for: version)
            if !AsrModels.modelsExist(at: cacheDir, version: version) {
                emit(["event": "diagnostic", "message":
                    "parakeet: downloading model (~480 MB, one-time)…"])
            }
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let layers = await manager.decoderLayerCount
            var state = TdtDecoderState.make(decoderLayers: layers)
            _ = try? await manager.transcribe(
                [Float](repeating: 0, count: 8_000), decoderState: &state)
            installManager(manager, layers: layers)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            emit(["event": "diagnostic",
                  "message": "parakeet: ready (\(version)) in \(ms)ms"])
        } catch {
            emit(["event": "diagnostic", "message":
                "parakeet: unavailable, using Apple finals — "
                + error.localizedDescription])
        }
    }

    func beginTake() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        converter?.reset() // drop the resampler tail from the last take
        capturing = true
        lock.unlock()
    }

    func endTake() -> [Float] {
        lock.lock()
        capturing = false
        let out = samples
        samples = []
        lock.unlock()
        return out
    }

    func cancelTake() {
        lock.lock()
        capturing = false
        samples = []
        lock.unlock()
    }

    // Called from the mic tap thread with whatever format the device gives.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard capturing else { return }
        if converter == nil
            || !audioFormatsMatch(converter!.inputFormat, buffer.format) {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
        }
        guard let converter else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(
            pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0, let channels = out.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channels[0], count: Int(out.frameLength)))
        }
    }

    // Transcribe a finished take, bounded by a deadline. nil = not ready,
    // failed, produced nothing, or too slow — the caller pastes Apple's text.
    func transcribe(_ takeSamples: [Float], within seconds: Double) async -> String? {
        let (manager, layers) = managerSnapshot()
        guard let manager, takeSamples.count >= Self.minimumSamples else {
            return nil
        }

        let work = Task { () -> String? in
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try? await manager.transcribe(
                takeSamples, decoderState: &state)
            let text = result?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
        let timeout = Task { () -> String? in
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let race = TimeoutRace<String?>()
        let winner = await withCheckedContinuation { continuation in
            Task { await race.resume(continuation, value: await work.value) }
            Task { await race.resume(continuation, value: await timeout.value) }
        }
        if winner != nil {
            timeout.cancel()
        } else {
            work.cancel()
        }
        return winner
    }

    // Debug hook: transcribe an audio file (any format; FluidAudio converts)
    // so the pipeline can be exercised without speaking into the mic.
    func transcribeFile(_ path: String) async -> String? {
        let (manager, layers) = managerSnapshot()
        guard let manager else { return nil }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try? await manager.transcribe(
            URL(fileURLWithPath: path), decoderState: &state)
        return result?.text
    }

    // Debug hook: drive a file through the REAL take path — beginTake(),
    // append() (which resamples the device format to 16 kHz), endTake(), and
    // transcribe() — rather than FluidAudio's own file loader. This is the
    // exact buffering/resampling code the live mic uses, so it can be
    // verified without speaking. Feed a 48 kHz file to exercise the 48→16
    // downsample a real mic needs.
    func selfTest(_ path: String, within seconds: Double) async -> String? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
        else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 4_800 // tap-sized bursts
        beginTake()
        while true {
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: chunk) else { break }
            do { try file.read(into: buf, frameCount: chunk) }
            catch { break }
            if buf.frameLength == 0 { break }
            append(buf)
        }
        return await transcribe(endTake(), within: seconds)
    }
}
