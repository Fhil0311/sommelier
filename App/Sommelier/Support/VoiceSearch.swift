// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Speech

/// Speaking a search: the Mac's microphone through Apple's speech recognition, in the app's language, on the
/// Mac itself when it can (`requiresOnDeviceRecognition` where supported). What was heard so far comes in as it
/// is recognised; a pause of a second and a half, or `stop`, ends it.
@MainActor @Observable
final class VoiceSearch {
    enum Phase: Equatable { case idle, listening, denied, unavailable }

    private(set) var phase = Phase.idle
    /// The words heard so far.
    private(set) var heard = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored var onHeard: ((String) -> Void)?

    /// The language to listen in first (the on-screen keyboard's layout); others follow if it can't be heard.
    @ObservationIgnored var language: String?
    /// Words the recognizer should expect: the library's game titles.
    @ObservationIgnored var hints: [String] = []

    func toggle() { phase == .listening ? stop() : start() }

    /// A recognizer for the first language macOS can listen in: the keyboard's, then the Mac's languages, then
    /// Russian and English. macOS has none for some languages (Belarusian among them), and the app's own
    /// language alone would then leave voice search dead.
    static func recognizer(preferring language: String?) -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()
        let candidates = [language].compactMap { $0 } + Locale.preferredLanguages + ["ru-RU", "en-US"]
        for candidate in candidates {
            let wanted = Locale(identifier: candidate)
            let code = wanted.language.languageCode?.identifier
            // The exact locale, else one of the same language (ru-BY → ru-RU, en-BY → en-GB/en-US).
            let match = supported.first { $0.identifier.replacingOccurrences(of: "_", with: "-") == candidate }
                ?? supported.first { $0.language.languageCode?.identifier == code && $0.identifier.hasSuffix("US") }
                ?? supported.first { $0.language.languageCode?.identifier == code }
            if let match, let recognizer = SFSpeechRecognizer(locale: match), recognizer.isAvailable { return recognizer }
        }
        return nil
    }

    func start() {
        guard phase != .listening else { return }
        heard = ""
        Task {
            // macOS answers on a queue of its own: asked from outside the main actor.
            let speech = await Self.speechAllowed()
            let microphone = speech ? await AVCaptureDevice.requestAccess(for: .audio) : false
            if speech && microphone { begin() } else { ControllerLog.note("voice: speech \(speech), microphone \(microphone)"); phase = .denied }
        }
    }

    nonisolated private static func speechAllowed() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in done.resume(returning: status == .authorized) }
        }
    }

    /// The microphone's sound into the request, on the audio thread.
    nonisolated private static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognise(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              _ handle: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { @Sendable result, error in
            handle(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
        }
    }

    private func begin() {
        guard let recognizer = Self.recognizer(preferring: language) else {
            ControllerLog.note("voice: no speech recognizer for \(language ?? "-") or \(Locale.preferredLanguages)")
            phase = .unavailable; return
        }
        ControllerLog.note("voice: listening in \(recognizer.locale.identifier), on this Mac \(recognizer.supportsOnDeviceRecognition)")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.contextualStrings = hints
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        Self.tap(engine.inputNode, into: request)
        engine.prepare()
        do { try engine.start() } catch { ControllerLog.note("voice: microphone didn't start: \(error)"); phase = .unavailable; return }
        phase = .listening
        task = Self.recognise(recognizer, request) { [weak self] text, final in
            Task { @MainActor in
                guard let self else { return }
                if let text { self.heard = text; self.onHeard?(text); self.quietThenStop() }
                if final { self.stop() }
            }
        }
        quietThenStop()
    }

    /// Ends after a second and a half with nothing new heard (eight seconds before the first word).
    private func quietThenStop() {
        silence?.cancel()
        let wait: Double = heard.isEmpty ? 8 : 1.5
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        silence?.cancel(); silence = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        if phase == .listening { phase = .idle }
    }
}
