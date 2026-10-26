import Foundation
import Speech
import AVFoundation

/// Push-to-talk speech recognition (on-device when available, zh-CN by default).
@MainActor
final class VoiceInput {
    static let shared = VoiceInput()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finish: ((String) -> Void)?
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: Settings.targetLang.contains("English") ? "en-US" : "zh-CN"))

    func start(onPartial: @escaping (String) -> Void) {
        latest = ""
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { onPartial(L("（请在系统设置 → 隐私与安全 → 语音识别 中允许 Readlet）")); return }
                self.begin(onPartial)
            }
        }
    }

    private func begin(_ onPartial: @escaping (String) -> Void) {
        guard let rec = recognizer, rec.isAvailable else { onPartial(L("（语音识别不可用）")); return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            #if os(iOS)
            Narrator.configurePlaybackAudioSession()
            #endif
            onPartial(LF("（无法使用麦克风：%@）", error.localizedDescription))
            return
        }
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let r = result { self.latest = r.bestTranscription.formattedString; onPartial(self.latest) }
                if (result?.isFinal ?? false) || err != nil { self.done() }
            }
        }
    }

    func stop(_ completion: @escaping (String) -> Void) {
        finish = completion
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        // give the recognizer a moment to deliver the final result
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.done() }
    }

    private func done() {
        guard let f = finish else { return }
        finish = nil
        task?.cancel(); task = nil; request = nil
        #if os(iOS)
        Narrator.configurePlaybackAudioSession()
        #endif
        f(latest)
    }
}
