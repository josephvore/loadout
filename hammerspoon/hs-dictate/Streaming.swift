// Streaming.swift — live first-pass ASR for hs-dictate.
//
// Apple's SpeechTranscriber drives the live overlay today, but its volatile
// partials are the weak link the user watches while speaking (mishears,
// choppy breaks, random capitalization). This replaces that live feed with
// Parakeet's cache-aware streaming encoder — FluidAudio's StreamingAsrManager
// running the Parakeet EOU 120M model on the Neural Engine. Audio is
// transcribed WHILE you speak and the partial transcript updates roughly
// every chunk (160 ms), so the pill reads like ChatGPT/Groq voice input.
//
// This is only the FIRST pass — the live preview. The authoritative FINAL
// still comes from the batch Parakeet 0.6b pass in Parakeet.swift, which has
// materially lower word error rate over the whole take. So the live text is
// snappy and good, and the pasted text stays best-in-class. EOU's own
// end-of-utterance segmentation therefore never affects what gets pasted.
//
// Threading: the mic tap hands every buffer to `append` synchronously, like
// ParakeetPass. The FluidAudio manager is an actor whose `appendAudio` is
// isolated, so the tap can't call it directly; instead `append` deep-copies
// the buffer (the tap's storage is recycled the moment the callback returns)
// into an owned queue, and a single serial pump task drains that queue into
// the manager and pulls partials. One pump task = in-order audio, no races.

import AVFoundation
import Foundation
import FluidAudio

// Thread-safe tally for the streaming debug hook: the partial callback fires
// from the manager's executor, so guard the counters with a lock.
private final class PartialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var last = ""
    func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        last = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func snapshot() -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        return (count, last)
    }
}

final class StreamingPass: @unchecked Sendable {
    private let lock = NSLock()
    private let variant: StreamingModelVariant
    private var manager: (any StreamingAsrManager)?
    private var pending: [AVAudioPCMBuffer] = []
    private var capturing = false
    private var generation = 0
    private var pumpTask: Task<Void, Never>?
    private var partialHandler: (@Sendable (String) -> Void)?

    // 16 kHz mono — the format the manager wants; used only for warmup.
    private let warmupFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    init(variant: StreamingModelVariant) {
        self.variant = variant
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return manager != nil
    }

    // Where live partials go. Set once at startup; routed through the Dictator
    // so it can arbitrate between Apple partials (until the stream warms) and
    // stream partials (once they start flowing).
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        partialHandler = handler
    }

    private func managerSnapshot() -> (any StreamingAsrManager)? {
        lock.lock(); defer { lock.unlock() }
        return manager
    }

    // NSLock must not be taken directly inside an async function; this
    // synchronous helper keeps the critical section out of the async frame.
    private func installManager(_ mgr: any StreamingAsrManager) {
        lock.lock(); defer { lock.unlock() }
        manager = mgr
    }

    // Download (first run only, ~120 MB) + load the CoreML models, wire the
    // partial callback, and warm the encoder so the first take doesn't pay ANE
    // instantiation. Runs off the ready path; Apple partials cover the gap
    // while this lands. Emits a diagnostic either way for the Lua log.
    func prepare() async {
        let started = Date()
        let mgr = variant.createManager()
        do {
            try await mgr.loadModels()
            await mgr.setPartialTranscriptCallback { [weak self] text in
                self?.emitPartial(text)
            }
            // Warm the encoder with ~0.5 s of silence, then reset, so the
            // first real chunk doesn't pay CoreML shape instantiation live.
            if let warm = AVAudioPCMBuffer(
                pcmFormat: warmupFormat, frameCapacity: 8_000) {
                warm.frameLength = 8_000
                try? await mgr.appendAudio(warm)
                try? await mgr.processBufferedAudio()
                try? await mgr.reset()
            }
            installManager(mgr)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            emit(["event": "diagnostic",
                  "message": "streaming: ready (\(variant.rawValue)) in \(ms)ms"])
        } catch {
            emit(["event": "diagnostic", "message":
                "streaming: unavailable, using Apple partials — "
                + error.localizedDescription])
        }
    }

    // Deliver a live partial, gated to an in-progress take so a late callback
    // after stop never clobbers the pasted final.
    private func emitPartial(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.lock()
        let live = capturing
        let handler = partialHandler
        lock.unlock()
        guard live, let handler else { return }
        handler(t)
    }

    func beginTake() {
        let mgr = managerSnapshot()
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        capturing = true
        generation += 1
        let gen = generation
        lock.unlock()
        guard let mgr else { return }

        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            try? await mgr.reset()
            while !Task.isCancelled {
                let batch = self?.drain() ?? []
                for buf in batch {
                    try? await mgr.appendAudio(buf)
                }
                if !batch.isEmpty {
                    try? await mgr.processBufferedAudio()
                }
                // Exit once this take ended and its audio is flushed, or a new
                // take superseded this pump.
                if self?.shouldStopPump(gen) ?? true { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private func shouldStopPump(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (!capturing && pending.isEmpty) || gen != generation
    }

    // Stop live partials immediately (the final owns the pill from here); the
    // pump drains any remaining queued audio and exits on its own.
    func endTake() {
        lock.lock()
        capturing = false
        lock.unlock()
    }

    func cancelTake() {
        lock.lock()
        capturing = false
        pending.removeAll()
        lock.unlock()
        pumpTask?.cancel()
    }

    // Called from the mic tap thread. Deep-copy (the tap reuses the buffer's
    // backing store after this returns) and enqueue for the pump.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard capturing, manager != nil else { return }
        guard let copy = Self.deepCopy(buffer) else { return }
        // Bound memory if the pump ever stalls (it shouldn't) — 512 tap
        // buffers is many seconds of headroom.
        if pending.count < 512 { pending.append(copy) }
    }

    // Debug hook: drive an audio file straight through the streaming manager,
    // counting partial-transcript updates, to prove the model loads and emits
    // live partials without a mic. Returns "N partial updates; final: <text>".
    func transcribeFileStreaming(_ path: String) async -> String? {
        if managerSnapshot() == nil { await prepare() }
        guard let mgr = managerSnapshot(),
              let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
        else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 4_800 // tap-sized bursts
        let counter = PartialCounter()
        await mgr.setPartialTranscriptCallback { text in counter.note(text) }
        try? await mgr.reset()
        while true {
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: chunk) else { break }
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            if buf.frameLength == 0 { break }
            try? await mgr.appendAudio(buf)
            try? await mgr.processBufferedAudio()
        }
        let final = ((try? await mgr.finish()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Restore the live handler so real takes still route partials out.
        await mgr.setPartialTranscriptCallback { [weak self] text in
            self?.emitPartial(text)
        }
        let (count, last) = counter.snapshot()
        return "\(count) partial updates; final: \(final.isEmpty ? last : final)"
    }

    private static func deepCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(src[i].mDataByteSize))
            dst[i].mDataByteSize = src[i].mDataByteSize
        }
        return out
    }
}
