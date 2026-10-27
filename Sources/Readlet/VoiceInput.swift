import Foundation
import Speech
import AVFoundation

/// Push-to-talk speech recognition (on-device when available, zh-CN by default).
@MainActor
final class VoiceInput {
    static let shared = VoiceInput()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finish: ((String) -> Void)?
    private var sessionToken = UUID()
    private var wantsRecording = false
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: Settings.targetLang.contains("English") ? "en-US" : "zh-CN"))

    func start(onPartial: @escaping (String) -> Void) {
        releaseAudioHardware()
        latest = ""
        wantsRecording = true
        let token = UUID()
        sessionToken = token
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard self.wantsRecording, self.sessionToken == token else { return }
                guard status == .authorized else {
                    self.wantsRecording = false
                    onPartial(L("（请在系统设置 → 隐私与安全 → 语音识别 中允许 Readlet）"))
                    return
                }
                self.begin(onPartial, token: token)
            }
        }
    }

    private func begin(_ onPartial: @escaping (String) -> Void, token: UUID) {
        guard wantsRecording, sessionToken == token else { return }
        guard let rec = recognizer, rec.isAvailable else {
            wantsRecording = false
            onPartial(L("（语音识别不可用）"))
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        let eng = AVAudioEngine()
        engine = eng
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        eng.prepare()
        do { try eng.start() } catch {
            releaseAudioHardware()
            #if os(iOS)
            Narrator.configurePlaybackAudioSession()
            #endif
            onPartial(LF("（无法使用麦克风：%@）", error.localizedDescription))
            return
        }
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, self.sessionToken == token else { return }
                if let r = result { self.latest = r.bestTranscription.formattedString; onPartial(self.latest) }
                if (result?.isFinal ?? false) || err != nil { self.done() }
            }
        }
    }

    private func releaseAudioHardware() {
        if let eng = engine {
            if eng.isRunning { eng.stop() }
            eng.inputNode.removeTap(onBus: 0)
            eng.reset()
        }
        engine = nil
    }

    func stop(_ completion: @escaping (String) -> Void) {
        wantsRecording = false
        finish = completion
        releaseAudioHardware()
        request?.endAudio()
        if task == nil {
            done()
            return
        }
        // give the recognizer a moment to deliver the final result
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.done()
        }
    }

    func forceStop() {
        wantsRecording = false
        sessionToken = UUID()
        finish = nil
        releaseAudioHardware()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        #if os(iOS)
        Narrator.configurePlaybackAudioSession()
        #endif
    }

    private func done() {
        releaseAudioHardware()
        guard let f = finish else {
            task?.cancel(); task = nil; request = nil
            return
        }
        finish = nil
        task?.cancel(); task = nil; request = nil
        #if os(iOS)
        Narrator.configurePlaybackAudioSession()
        #endif
        f(latest)
    }
}
