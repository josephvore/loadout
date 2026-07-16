// hs-dictate — on-device streaming dictation daemon for Hammerspoon.
//
// Uses the macOS 26 SpeechAnalyzer / SpeechTranscriber API (with
// DictationTranscriber as a compatibility fallback) and an AVAudioEngine
// microphone tap. Audio is
// transcribed WHILE you speak, so the final transcript is available almost
// instantly when recording stops.
//
// Designed to run as a long-lived child of Hammerspoon (hs.task): the speech
// model and audio engine are prewarmed once, then each dictation is
// start/stop over a tiny line protocol.
//
// Latency design: starting AVAudioEngine is the slowest part of a take
// (~100-300 ms) and clips the first word, so the engine is kept HOT between
// takes — the tap stays installed and buffers are simply dropped while idle.
// The mic indicator stays on while hot; an idle timeout (--idle) releases
// the mic after a quiet period so it isn't held forever.
//
//   argv:  [locale] [--fast] [--punctuation] [--idle <seconds>]
//     --fast          ask for more frequent finalization
//     --punctuation   let Apple insert commas/periods. Off by default so
//                     pauses while thinking do not become punctuation.
//     --idle <sec>    release the mic after this many idle seconds
//                     (0 = release right after each take, <0 = hold forever)
//     --stop-grace <ms>  tail-audio grace after stop before finalize
//                     (default 150)
//     --parakeet <v2|v3|off>  second-pass Parakeet TDT ASR (FluidAudio
//                     CoreML on the Neural Engine). Re-transcribes each take's
//                     buffered audio for the final — roughly half Apple's
//                     word error rate at ~0.2s per take. Default off.
//     --stream <eou160|eou320|off>  first-pass streaming ASR (Parakeet EOU,
//                     FluidAudio cache-aware streaming encoder). Transcribes
//                     WHILE you speak and drives the live overlay with
//                     Parakeet-quality partials in place of Apple's volatile
//                     results. The batch --parakeet pass still owns the final.
//                     Default off.
//
//   stdin  (one command per line):  start | stop | cancel | quit
//   stdout (one JSON object per line):
//     {"event":"ready"}                      model loaded, idle
//     {"event":"started"}                    mic live, speak now
//     {"event":"partial","text":"..."}       live volatile transcript
//     {"event":"final","text":"..."}         finished transcript for the take
//     {"event":"canceled"}                   take discarded
//     {"event":"error","message":"..."}      something failed
//
// Build:  ./build.sh  (SwiftPM release build copied to ~/bin/hs-dictate;
// the FluidAudio dependency rules out a bare swiftc build)

import AVFoundation
import FluidAudio
import Foundation
import Speech

// Resume a timeout race once. The losing task may be stuck inside an Apple
// API; it must not keep the caller waiting.
actor TimeoutRace<Value: Sendable> {
    private var finished = false

    func resume(_ continuation: CheckedContinuation<Value, Never>,
                value: Value) {
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }
}

// MARK: - stdout JSON events

private let emitLock = NSLock()

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else { return }
    emitLock.lock()
    defer { emitLock.unlock() }
    print(line)
    fflush(stdout)
}

func emitError(_ message: String) { emit(["event": "error", "message": message]) }

func audioFormatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
    abs(a.sampleRate - b.sampleRate) < 0.5
        && a.channelCount == b.channelCount
        && a.commonFormat == b.commonFormat
        && a.isInterleaved == b.isInterleaved
}

// MARK: - Dictation engine

actor Dictator {
    private let locale: Locale
    private let fastResults: Bool
    private let punctuation: Bool
    private let micIdleSeconds: Double
    private let glossaryPath: String?
    private let correctionsPath: String?
    private let farField: Bool
    private var contextTerms: [String] = []

    private var analyzer: SpeechAnalyzer?
    private var speechTranscriber: SpeechTranscriber?
    private var dictationTranscriber: DictationTranscriber?
    private var recognizerEngine = "speech"
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var tapFormat: AVAudioFormat?
    private var engineHot = false
    private var recording = false
    private var canceled = false
    private var finalizedText = ""
    private var lastVolatile = ""
    private var takeGen = 0 // invalidates results from abandoned takes

    // finalize flushes the last words of a take, but the OS call has been
    // seen to hang; never make the user wait longer than this — the
    // streamed text is already in hand.
    private let finalizeTimeout = 1.0
    private let stopTailGraceMs: UInt64

    // Second-pass Parakeet recognizer (nil = disabled). It runs concurrently
    // with Apple's finalize on stop; whichever transcript it produces within
    // this budget wins, otherwise Apple's text pastes as before.
    private let parakeet: ParakeetPass?
    private let parakeetTimeout = 1.2

    // First-pass streaming recognizer (nil = disabled). Drives the live pill
    // with Parakeet-quality partials in place of Apple's volatile results;
    // the batch `parakeet` pass above still owns the final transcript.
    private let streaming: StreamingPass?
    // Set once a stream partial has arrived this take; from then on Apple's
    // volatile partials are suppressed so the pill has a single source.
    private var streamPartialSeen = false

    // Shared with the (nonisolated) tap callback. converter/format are only
    // mutated while the engine is stopped; continuation flips at take
    // boundaries and a stray yield after finish() is a harmless no-op.
    nonisolated(unsafe) private var convParams:
        (converter: AVAudioConverter?, format: AVAudioFormat?,
         continuation: AsyncStream<AnalyzerInput>.Continuation?) = (nil, nil, nil)
    nonisolated(unsafe) private var lastLevelEmit = 0.0

    init(locale: Locale, fastResults: Bool, punctuation: Bool,
         micIdleSeconds: Double, glossaryPath: String?,
         correctionsPath: String?, farField: Bool,
         stopTailGraceMs: UInt64, parakeet: ParakeetPass?,
         streaming: StreamingPass?) {
        self.locale = locale
        self.fastResults = fastResults
        self.punctuation = punctuation
        self.micIdleSeconds = micIdleSeconds
        self.glossaryPath = glossaryPath
        self.correctionsPath = correctionsPath
        self.farField = farField
        self.stopTailGraceMs = stopTailGraceMs
        self.parakeet = parakeet
        self.streaming = streaming
    }

    private func makeSpeechTranscriber() -> SpeechTranscriber {
        // Volatile results keep the live overlay responsive. Deliberately do
        // not enable fastResults: Apple documents that speed bias as less
        // accurate, and the daemon already keeps the model and mic warm.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private func makeDictationTranscriber() -> DictationTranscriber {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        if farField { preset.contentHints.insert(.farField) }
        preset.transcriptionOptions.remove(.punctuation)
        preset.transcriptionOptions.remove(.emoji)
        preset.transcriptionOptions.remove(.etiquetteReplacements)
        if punctuation {
            preset.transcriptionOptions.insert(.punctuation)
        }
        preset.reportingOptions.insert(.volatileResults)
        if fastResults {
            preset.reportingOptions.insert(.frequentFinalization)
        }

        return DictationTranscriber(locale: locale, preset: preset)
    }

    private func audioError(_ msg: String) -> NSError {
        NSError(domain: "hs-dictate", code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func installAssets(supporting module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]) {
            emit(["event": "downloading", "message": "downloading speech model…"])
            try await request.downloadAndInstall()
        }
    }

    private func containsLocale(_ locales: [Locale]) -> Bool {
        locales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
    }

    private func prepareRecognizer() async throws {
        let speechLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: locale)
        if SpeechTranscriber.isAvailable, speechLocale != nil {
            do {
                recognizerEngine = "speech"
                let candidate = makeSpeechTranscriber()
                if !containsLocale(await SpeechTranscriber.installedLocales) {
                    try await installAssets(supporting: candidate)
                }
                try await rebuild()
                return
            } catch {
                emit(["event": "diagnostic", "message":
                    "SpeechTranscriber unavailable; using compatibility fallback: "
                    + error.localizedDescription])
            }
        }

        let supported = await DictationTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw NSError(domain: "hs-dictate", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "locale \(locale.identifier) is unsupported by both transcribers"
            ])
        }
        recognizerEngine = "dictation"
        let candidate = makeDictationTranscriber()
        if !containsLocale(await DictationTranscriber.installedLocales) {
            try await installAssets(supporting: candidate)
        }
        try await rebuild()
    }

    // Ensure the best on-device model for `locale` is installed, build the
    // analyzer, preheat it, and bring the mic up hot.
    func prepare() async throws {
        try await prepareRecognizer()
        // Make "ready" mean the audio path is already open. Otherwise the
        // first real take pays the AVAudioEngine/tap startup cost.
        try await startAudioRecovering()

        // Keep the model and mic warm until the idle timer releases them.
        scheduleIdleStop()
    }

    // Install the mic tap (once, or again after a device change) and start
    // the engine if it isn't already running.
    private func startAudioIfNeeded() throws {
        guard let analyzerFormat else { throw audioError("engine not prepared") }
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw audioError("no usable microphone input (sample rate 0)")
        }

        // Device may have changed while the engine was idle-stopped; the tap
        // must match the live input format.
        if tapInstalled, let tf = tapFormat,
           !audioFormatsMatch(tf, micFormat) {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }

        if !tapInstalled {
            // AVAudioEngine throws an Objective-C exception (process abort)
            // when a tap is already present. Our bookkeeping can get stale
            // after Bluetooth/default-device churn, so clear the bus directly
            // before installing a new tap.
            engine.stop()
            input.removeTap(onBus: 0)
            engine.reset()

            // Convert whatever the input device provides (e.g. AirPods at
            // 24 kHz) to the analyzer's preferred format.
            guard let converter = AVAudioConverter(from: micFormat,
                                                   to: analyzerFormat) else {
                throw audioError("cannot convert mic format to analyzer format")
            }
            convParams = (converter, analyzerFormat, convParams.continuation)

            // Small buffers (~21 ms at 48 kHz) keep partials snappy and lose
            // less tail audio when a take stops. Passing nil lets CoreAudio use
            // the live device format; passing a stale explicit format can abort
            // the process with an Objective-C AVAudioEngine exception.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) {
                [weak self] buffer, _ in
                guard let self else { return }
                // Parakeet buffers the take's raw audio independently of the
                // Apple analyzer feed (it self-gates on capture state); the
                // streaming pass likewise deep-copies and queues each buffer.
                self.parakeet?.append(buffer)
                self.streaming?.append(buffer)
                let params = self.convParams
                guard let continuation = params.continuation,
                      let outFormat = params.format else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastLevelEmit >= (1.0 / 15.0),
                   let channels = buffer.floatChannelData,
                   buffer.frameLength > 0 {
                    let samples = channels[0]
                    var sum: Float = 0
                    for i in 0..<Int(buffer.frameLength) {
                        let value = samples[i]
                        sum += value * value
                    }
                    let rms = sqrt(sum / Float(buffer.frameLength))
                    let db = 20 * log10(max(rms, 0.000_001))
                    let level = max(0, min(1, (Double(db) + 55) / 45))
                    self.lastLevelEmit = now
                    emit(["event": "level", "value": level])
                }
                var converter = params.converter
                if converter == nil
                    || !audioFormatsMatch(converter!.inputFormat, buffer.format) {
                    guard let rebuilt = AVAudioConverter(from: buffer.format,
                                                         to: outFormat) else { return }
                    self.convParams.converter = rebuilt
                    converter = rebuilt
                }
                guard let activeConverter = converter else { return }
                let ratio = outFormat.sampleRate / buffer.format.sampleRate
                let capacity =
                    AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let out = AVAudioPCMBuffer(
                    pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var err: NSError?
                var fed = false
                activeConverter.convert(to: out, error: &err) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if err == nil, out.frameLength > 0 {
                    continuation.yield(AnalyzerInput(buffer: out))
                }
            }
            tapInstalled = true
            tapFormat = micFormat
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        engineHot = true
    }

    private func releaseAudioTap() {
        convParams.continuation = nil
        inputContinuation?.finish()
        inputContinuation = nil

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        tapInstalled = false
        tapFormat = nil
        engineHot = false
    }

    private func finishActiveInput() {
        convParams.continuation = nil
        inputContinuation?.finish()
        inputContinuation = nil
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = nil
        if micIdleSeconds < 0 { return } // hold the mic forever
        if micIdleSeconds == 0 {
            stopEngineIfIdle()
            return
        }
        let secs = micIdleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            if Task.isCancelled { return }
            await self?.stopEngineIfIdle()
        }
    }

    private func stopEngineIfIdle() {
        guard !recording else { return }
        releaseAudioTap()
    }

    private func startAudioRecovering() async throws {
        do {
            try startAudioIfNeeded()
        } catch {
            releaseAudioTap()
            try? await Task.sleep(for: .milliseconds(150))
            try await rebuild()
            try startAudioIfNeeded()
        }
    }

    func start() async {
        guard !recording else { return }
        guard let analyzer, analyzerFormat != nil,
              speechTranscriber != nil || dictationTranscriber != nil else {
            emitError("engine not prepared")
            return
        }

        idleTask?.cancel()
        idleTask = nil
        do {
            try await startAudioRecovering()
        } catch {
            emitError("mic start: \(error.localizedDescription)")
            return
        }

        canceled = false
        finalizedText = ""
        lastVolatile = ""
        takeGen += 1
        let gen = takeGen
        convParams.converter?.reset() // drop resampler tail from the last take
        parakeet?.beginTake()
        streamPartialSeen = false
        if streaming?.isReady == true { streaming?.beginTake() }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        // Capture from this instant — the engine is already running, so even
        // speech that begins before "started" is heard.
        convParams.continuation = continuation

        // Consume results for this take. Volatile results give the live
        // partial transcript; finalized results accumulate into the answer.
        if let transcriber = speechTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            await self?.appendFinal(text, gen: gen)
                        } else {
                            await self?.noteVolatile(text, gen: gen)
                        }
                    }
                } catch is CancellationError {
                    // expected: abandoned takes are cancelled during teardown
                } catch {
                    emitError("results: \(error.localizedDescription)")
                }
            }
        } else if let transcriber = dictationTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            await self?.appendFinal(text, gen: gen)
                        } else {
                            await self?.noteVolatile(text, gen: gen)
                        }
                    }
                } catch is CancellationError {
                    // expected: abandoned takes are cancelled during teardown
                } catch {
                    emitError("results: \(error.localizedDescription)")
                }
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            convParams.continuation = nil
            inputContinuation?.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            resultsTask = nil
            emitError("analyzer start: \(error.localizedDescription)")
            scheduleIdleStop()
            return
        }

        recording = true
        emit(["event": "started"])
    }

    private func joinTranscript(_ left: String, _ right: String) -> String {
        let l = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if l.isEmpty { return r }
        if r.isEmpty { return l }
        if let first = r.first, ",.!?;:)]}".contains(first) {
            return l + r
        }
        return l + " " + r
    }

    private func appendFinal(_ text: String, gen: Int) {
        guard gen == takeGen else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if finalizedText.isEmpty {
            finalizedText = t
        } else if t.hasPrefix(finalizedText) {
            // Some transcriber builds report cumulative final text.
            finalizedText = t
        } else if !finalizedText.hasSuffix(t) {
            // Other builds report final segments. Join them without word jams.
            finalizedText = joinTranscript(finalizedText, t)
        }
        lastVolatile = "" // the final supersedes the volatile for its range
    }

    private func noteVolatile(_ text: String, gen: Int) {
        guard gen == takeGen, !text.isEmpty else { return }
        lastVolatile = text
        // Apple drives the pill only until the stream produces its first
        // partial (or for the whole take when streaming is off/still loading).
        // lastVolatile keeps updating regardless, so bestText() stays a valid
        // fallback for the final if Parakeet's batch pass comes up empty.
        if recording && !streamPartialSeen {
            emit(["event": "partial", "text": bestText()])
        }
    }

    // Live partial from the streaming first pass. The first one to arrive
    // takes the pill for the rest of the take, suppressing Apple's volatile
    // partials so the overlay has a single, better source.
    func streamPartial(_ text: String) {
        guard recording else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        streamPartialSeen = true
        emit(["event": "partial", "text": t, "source": "stream"])
    }

    // The best transcript available right now: finalized segments plus the
    // still-volatile tail. This is what gets pasted if finalize is slow.
    private func bestText() -> String {
        let f = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = lastVolatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return v }
        if v.isEmpty { return f }
        if v.hasPrefix(f) { return v }
        if f.hasSuffix(v) { return f }
        return joinTranscript(f, v)
    }

    // Finalize the take's tail, bounded by a deadline: everything the model
    // has heard becomes a refined final result. Only finalize — teardown is
    // the caller's job, off the critical path. Returns false on timeout.
    private func finalizeWithTimeout(_ seconds: Double) async -> Bool {
        guard let analyzer else { return true }
        let finalizeTask = Task {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            // Give the results loop a beat to consume the finals that
            // finalize just produced before bestText() is read.
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let race = TimeoutRace<Bool>()

        let winner = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                await race.resume(continuation,
                                  value: await finalizeTask.value)
            }
            Task {
                await race.resume(continuation,
                                  value: await timeoutTask.value)
            }
        }
        if winner {
            timeoutTask.cancel()
        } else {
            finalizeTask.cancel()
        }
        return winner
    }

    func stop() async {
        guard recording else {
            if canceled {
                canceled = false
                emit(["event": "canceled"])
            } else {
                emit(["event": "final", "text": ""])
            }
            return
        }
        recording = false
        streaming?.endTake() // stop live partials; the final owns the pill now

        if !canceled {
            // Let the tap deliver the last buffers generated by the trigger
            // release before ending the analyzer input.
            try? await Task.sleep(for: .milliseconds(stopTailGraceMs))
        }
        finishActiveInput()

        var appleFinalize: Task<Bool, Never>? = nil
        if canceled {
            // Nothing to finalize — discard instantly.
            parakeet?.cancelTake()
            streaming?.cancelTake()
            emit(["event": "canceled"])
        } else {
            let takeSamples = parakeet?.endTake() ?? []
            // Run Apple's finalize and Parakeet concurrently. Parakeet's
            // transcript wins when it lands inside its budget (it is the
            // more accurate engine); Apple's bestText() is the fallback and
            // is only waited on when actually needed.
            let finalize = Task { await self.finalizeWithTimeout(self.finalizeTimeout) }
            appleFinalize = finalize
            var text: String? = nil
            var engine = recognizerEngine
            if let parakeet,
               let pk = await parakeet.transcribe(takeSamples,
                                                  within: parakeetTimeout) {
                text = pk
                engine = "parakeet"
            }
            if text == nil {
                _ = await finalize.value
                text = bestText()
            }
            emit(["event": "final", "text": text ?? "", "engine": engine])
        }

        takeGen += 1 // any stragglers from this take are ignored from here on

        // The user already has their text; tear the used analyzer down off
        // the critical path (it may be wedged — cancelAndFinishNow copes).
        // Let a still-running finalize settle first so the two Apple calls
        // don't race on the same analyzer.
        let stale = analyzer
        let staleResults = resultsTask
        resultsTask = nil
        Task {
            if let appleFinalize { _ = await appleFinalize.value }
            await stale?.cancelAndFinishNow()
            staleResults?.cancel()
        }

        // Rebuild for the next take (cheap — the model stays loaded).
        do { try await rebuild() } catch {
            emitError("rebuild: \(error.localizedDescription)")
        }
        scheduleIdleStop()
    }

    func cancel() async {
        canceled = true
        await stop()
    }

    func reloadContext() async {
        guard let analyzer else { return }
        do {
            try await installContext(on: analyzer)
            emit(["event": "context", "count": contextTerms.count])
        } catch {
            emitError("reload context: \(error.localizedDescription)")
        }
    }

    func readyFields() -> [String: Any] {
        ["event": "ready", "contextCount": contextTerms.count,
         "engine": recognizerEngine]
    }

    private func canonicalTerm(_ line: String) -> String? {
        let comment = line.firstIndex(of: "#") ?? line.endIndex
        let cleaned = line[..<comment]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        for separator in ["=>", "="] {
            if let range = cleaned.range(of: separator) {
                let value = cleaned[..<range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return cleaned
    }

    private func correctionTarget(_ line: String) -> String? {
        let comment = line.firstIndex(of: "#") ?? line.endIndex
        let cleaned = line[..<comment]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["\t", "=>"] {
            if let range = cleaned.range(of: separator) {
                let value = cleaned[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func loadContextTerms() -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ term: String?) {
            guard terms.count < 100, let term else { return }
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            terms.append(term)
        }
        if let glossaryPath,
           let contents = try? String(contentsOfFile: glossaryPath, encoding: .utf8) {
            contents.enumerateLines { line, _ in add(self.canonicalTerm(line)) }
        }
        if let correctionsPath,
           let contents = try? String(contentsOfFile: correctionsPath, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines).reversed() {
                add(correctionTarget(line))
            }
        }
        return terms
    }

    private func installContext(on analyzer: SpeechAnalyzer) async throws {
        contextTerms = loadContextTerms()
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextTerms
        try await analyzer.setContext(context)
    }

    private func rebuild() async throws {
        let module: any SpeechModule
        if recognizerEngine == "speech" {
            let transcriber = makeSpeechTranscriber()
            speechTranscriber = transcriber
            dictationTranscriber = nil
            module = transcriber
        } else {
            let transcriber = makeDictationTranscriber()
            dictationTranscriber = transcriber
            speechTranscriber = nil
            module = transcriber
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await installContext(on: analyzer)
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module])
        if tapInstalled,
           let analyzerFormat,
           let converter = AVAudioConverter(from: engine.inputNode.outputFormat(forBus: 0),
                                            to: analyzerFormat) {
            convParams = (converter, analyzerFormat, convParams.continuation)
        }
        // Preheat so the next take's first buffer is processed immediately
        // (loads the model on the very first call; near-free afterwards).
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
    }
}

// MARK: - main

var localeID = "en_US"
var fastResults = false
var punctuation = false
var micIdleSeconds = 180.0
var glossaryPath: String?
var correctionsPath: String?
var farField = false
// Tap buffers are ~21 ms at 48 kHz, so 150 ms still catches the release
// tail with a wide margin while shaving ~150 ms off every stop.
var stopGraceMs: UInt64 = 150
// Parakeet second-pass ASR: "v2" (English-only), "v3" (multilingual), "off".
var parakeetChoice = "off"
// Streaming first-pass ASR for live partials: "eou160", "eou320", or "off".
var streamChoice = "off"

var argi = 1
let argv = CommandLine.arguments
while argi < argv.count {
    switch argv[argi] {
    case "--fast":
        fastResults = true
    case "--punctuation":
        punctuation = true
    case "--idle":
        argi += 1
        if argi < argv.count { micIdleSeconds = Double(argv[argi]) ?? 180.0 }
    case "--glossary":
        argi += 1
        if argi < argv.count { glossaryPath = argv[argi] }
    case "--corrections":
        argi += 1
        if argi < argv.count { correctionsPath = argv[argi] }
    case "--content-hint":
        argi += 1
        if argi < argv.count { farField = argv[argi] == "far-field" }
    case "--stop-grace":
        argi += 1
        if argi < argv.count { stopGraceMs = UInt64(argv[argi]) ?? 150 }
    case "--parakeet":
        argi += 1
        if argi < argv.count { parakeetChoice = argv[argi] }
    case "--stream":
        argi += 1
        if argi < argv.count { streamChoice = argv[argi] }
    default:
        localeID = argv[argi]
    }
    argi += 1
}

let parakeetVersion: AsrModelVersion? = switch parakeetChoice {
case "v2": .v2
case "v3": .v3
default: nil
}
let parakeet: ParakeetPass? = parakeetVersion != nil ? ParakeetPass() : nil

// Streaming first pass: Parakeet EOU cache-aware streaming encoder for the
// live pill. 160 ms chunks = lowest latency; 320 ms = a bit more accurate.
let streamVariant: StreamingModelVariant? = switch streamChoice {
case "eou160": .parakeetEou160ms
case "eou320": .parakeetEou320ms
default: nil
}
let streaming: StreamingPass? = streamVariant.map { StreamingPass(variant: $0) }

let dictator = Dictator(locale: Locale(identifier: localeID),
                        fastResults: fastResults,
                        punctuation: punctuation,
                        micIdleSeconds: micIdleSeconds,
                        glossaryPath: glossaryPath,
                        correctionsPath: correctionsPath,
                        farField: farField,
                        stopTailGraceMs: stopGraceMs,
                        parakeet: parakeet,
                        streaming: streaming)

// Request mic permission up front so the TCC prompt (attributed to
// Hammerspoon when spawned from hs.task) happens at load, not first use.
let micOK = await AVCaptureDevice.requestAccess(for: .audio)
guard micOK else {
    emitError("microphone permission denied")
    exit(1)
}

do {
    try await dictator.prepare()
} catch {
    emitError("prepare: \(error.localizedDescription)")
    exit(1)
}

emit(await dictator.readyFields())

// Parakeet loads AFTER ready so Apple prep and the first take are never
// blocked; takes that stop before it lands simply use Apple finals.
// Detached (not a plain Task): top-level code is @MainActor, and an
// inherited-isolation Task would need the main actor to resume after each
// await — but the readLine loop below blocks the main thread between
// commands, so its continuations would never run. Detached keeps the whole
// load on the global executor.
if let parakeet, let parakeetVersion {
    Task.detached { await parakeet.prepare(version: parakeetVersion) }
}

// Streaming first pass loads the same way — off the ready path, in the
// background. Route its partials through the actor so it can arbitrate with
// Apple's until the stream warms; the hop is cheap (~once per 160 ms chunk).
if let streaming {
    streaming.setPartialHandler { text in
        Task { await dictator.streamPartial(text) }
    }
    Task.detached { await streaming.prepare() }
}

// Command loop: read stdin lines forever. readLine() blocks its thread
// waiting for the next line, so run it on a detached task and await the
// result. Awaiting frees the main actor while we wait, so the concurrent
// Parakeet load (also off the main actor) makes progress between commands
// instead of deadlocking behind a blocked main thread.
while let line = await Task.detached(operation: {
    readLine(strippingNewline: true)
}).value {
    let command = line.trimmingCharacters(in: .whitespaces)
    switch command {
    case "start":  await dictator.start()
    case "stop":   await dictator.stop()
    case "cancel": await dictator.cancel()
    case "reload-context": await dictator.reloadContext()
    case "quit":   exit(0)
    case "":       continue
    default:
        // parakeet-file <path> — debug: transcribe an audio file through
        // Parakeet without touching the mic.
        if command.hasPrefix("parakeet-file ") {
            let path = String(command.dropFirst("parakeet-file ".count))
                .trimmingCharacters(in: .whitespaces)
            let text = await parakeet?.transcribeFile(path)
            emit(["event": "diagnostic",
                  "message": "parakeet-file: " + (text ?? "(unavailable)")])
        } else if command.hasPrefix("parakeet-selftest ") {
            // Exercises the real append()/endTake()/transcribe() take path.
            let path = String(command.dropFirst("parakeet-selftest ".count))
                .trimmingCharacters(in: .whitespaces)
            let text = await parakeet?.selfTest(path, within: 5.0)
            emit(["event": "diagnostic",
                  "message": "parakeet-selftest: " + (text ?? "(unavailable)")])
        } else if command.hasPrefix("stream-file ") {
            // Drive a file through the streaming first pass, counting partials.
            let path = String(command.dropFirst("stream-file ".count))
                .trimmingCharacters(in: .whitespaces)
            let text = await streaming?.transcribeFileStreaming(path)
            emit(["event": "diagnostic",
                  "message": "stream-file: " + (text ?? "(unavailable)")])
        } else {
            emitError("unknown command: \(line)")
        }
    }
}
