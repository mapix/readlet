import Foundation
import AVFoundation

/// Where narration audio comes from.
/// - system: macOS AVSpeechSynthesizer — free, offline, no model needed (default for new installs)
/// - gateway: OpenAI-compatible `POST /v1/audio/speech` on the main model gateway (same URL and key)
/// - the others: a speech service with its own base URL and key (see RemoteTTS)
enum TTSProvider: String, CaseIterable, Identifiable {
    case system, gateway, openai, gemini, qwen, azure, elevenlabs, minimax, volcengine
    var id: String { rawValue }
    var isRemote: Bool { self != .system }

    init?(configName s: String) {
        switch s.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "system", "macos", "apple", "avspeech", "local": self = .system
        case "gateway", "api", "remote": self = .gateway
        case "openai", "openai-compatible", "compatible", "siliconflow": self = .openai
        case "gemini", "google": self = .gemini
        case "qwen", "dashscope", "tongyi", "aliyun", "bailian": self = .qwen
        case "azure", "microsoft": self = .azure
        case "elevenlabs", "eleven": self = .elevenlabs
        case "minimax", "hailuo": self = .minimax
        case "volcengine", "volcano", "doubao", "bytedance": self = .volcengine
        default: return nil
        }
    }

    /// Chinese source label (localized with L())
    var title: String {
        switch self {
        case .system:
            #if os(iOS)
            return "系统语音（免费，无需模型）"
            #else
            return "系统语音（macOS，免费，无需模型）"
            #endif
        case .gateway: return "主网关（/v1/audio/speech）"
        case .openai: return "OpenAI 或兼容接口"
        case .gemini: return "Google Gemini"
        case .qwen: return "通义千问 Qwen-TTS（阿里云百炼）"
        case .azure: return "Microsoft Azure 语音"
        case .elevenlabs: return "ElevenLabs"
        case .minimax: return "MiniMax"
        case .volcengine: return "火山引擎 · 豆包语音"
        }
    }
    var shortTitle: String {
        switch self {
        case .system: return "系统语音"
        case .gateway: return "网关 TTS"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        case .azure: return "Azure"
        case .elevenlabs: return "ElevenLabs"
        case .minimax: return "MiniMax"
        case .volcengine: return "豆包"
        }
    }
    var providerNote: String {
        switch self {
        case .gateway: return L("网关需提供 OpenAI 兼容的 POST /v1/audio/speech。")
        case .openai: return L("OpenAI 官方，或任何兼容 POST /v1/audio/speech 的服务（如 SiliconFlow、本地 Kokoro）。")
        case .gemini: return L("使用 Gemini API 的 Interactions 接口，Key 来自 Google AI Studio。")
        case .qwen: return L("阿里云百炼 DashScope：北京地域用默认地址，新加坡地域改用 dashscope-intl。模型如 qwen3-tts-flash。")
        case .azure: return L("填写语音资源的 Key 和区域；音色用完整名称，如 zh-CN-XiaoxiaoNeural。")
        case .elevenlabs: return L("音色填 Voice ID，可在 ElevenLabs 的 Voice Library 中复制。")
        case .minimax: return L("国内用默认地址，海外账号改用 https://api.minimax.io。")
        case .volcengine: return L("在火山引擎控制台创建语音合成应用，填写 App ID 和 Access Token。")
        case .system: return ""
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .system, .gateway: return ""
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .qwen: return "https://dashscope.aliyuncs.com"
        case .azure: return ""                                   // derived from the region
        case .elevenlabs: return "https://api.elevenlabs.io"
        case .minimax: return "https://api.minimaxi.com"
        case .volcengine: return "https://openspeech.bytedance.com"
        }
    }
    var baseURLHint: String {
        switch self {
        case .qwen: return "https://dashscope.aliyuncs.com（国际站：https://dashscope-intl.aliyuncs.com）"
        case .minimax: return "https://api.minimaxi.com（海外：https://api.minimax.io）"
        case .azure: return "https://<region>.tts.speech.microsoft.com"
        case .openai: return "https://api.openai.com，或任意兼容 /v1/audio/speech 的服务"
        default: return defaultBaseURL
        }
    }
    var defaultModel: String {
        switch self {
        case .system, .azure: return ""
        case .gateway: return "gemini-3.8-flash-tts"
        case .openai: return "gpt-4o-mini-tts"
        case .gemini: return "gemini-3.8-flash-tts"
        case .qwen: return "qwen3-tts-flash"
        case .elevenlabs: return "eleven_multilingual_v2"
        case .minimax: return "speech-02-hd"
        case .volcengine: return "volcano_tts"            // the "cluster"
        }
    }
    var defaultVoice: String {
        switch self {
        case .system: return ""
        case .gateway, .gemini: return "Zephyr"
        case .openai: return "marin"
        case .qwen: return "Cherry"
        case .azure: return "zh-CN-XiaoxiaoNeural"
        case .elevenlabs: return "21m00Tcm4TlvDXrnALMq"
        case .minimax: return "female-shaonv"
        case .volcengine: return "zh_female_shuangkuaisisi_moon_bigtts"
        }
    }
    /// well-known voices for the picker (any other id can be typed in)
    var voiceSuggestions: [VoiceOption] {
        func v(_ id: String, _ label: String) -> VoiceOption { VoiceOption(id: id, label: label) }
        switch self {
        case .system: return []
        case .gateway, .gemini:
            return [v("Zephyr", "Zephyr · 明亮女声"), v("Leda", "Leda · 年轻轻松女声"), v("Aoede", "Aoede · 温柔女声"), v("Kore", "Kore · 沉稳女声"),
                    v("Puck", "Puck · 活泼男声"), v("Charon", "Charon · 知性男声"), v("Fenrir", "Fenrir · 激昂男声"), v("Orus", "Orus · 低沉男声")]
        case .openai:
            return ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"].map { v($0, $0) }
        case .qwen:
            return [v("Cherry", "Cherry · 芊悦（女）"), v("Serena", "Serena · 苏瑶（女）"), v("Ethan", "Ethan · 晨煦（男）"), v("Chelsie", "Chelsie · 千雪（女）"),
                    v("Momo", "Momo · 茉兔（女）"), v("Vivian", "Vivian · 十三（女）"), v("Moon", "Moon · 月白（男）"), v("Kai", "Kai · 凯（男）"),
                    v("Nofish", "Nofish · 不吃鱼（男）"), v("Jennifer", "Jennifer · 詹妮弗（女，英）"), v("Ryan", "Ryan · 甜茶（男，英）"), v("Dylan", "Dylan · 晓东（北京话）"),
                    v("Sunny", "Sunny · 晴儿（四川话）"), v("Rocky", "Rocky · 阿强（粤语）")]
        case .azure:
            return ["zh-CN-XiaoxiaoNeural", "zh-CN-YunxiNeural", "zh-CN-XiaoyiNeural", "zh-CN-YunjianNeural", "zh-CN-XiaochenMultilingualNeural",
                    "zh-TW-HsiaoChenNeural", "en-US-AvaMultilingualNeural", "en-US-AndrewMultilingualNeural", "en-US-JennyNeural", "ja-JP-NanamiNeural", "ko-KR-SunHiNeural"].map { v($0, $0) }
        case .elevenlabs:
            return [v("21m00Tcm4TlvDXrnALMq", "Rachel"), v("EXAVITQu4vr4xnSDxMaL", "Sarah"), v("pNInz6obpgDQGcFmaJgB", "Adam"), v("JBFqnCBsd6RMkjVDRZzb", "George")]
        case .minimax:
            return [v("female-shaonv", "少女音色"), v("female-yujie", "御姐音色"), v("female-chengshu", "成熟女性"), v("male-qn-qingse", "青涩青年"),
                    v("male-qn-jingying", "精英青年"), v("presenter_male", "男性主持人"), v("presenter_female", "女性主持人"), v("audiobook_male_1", "男性有声书")]
        case .volcengine:
            return [v("zh_female_shuangkuaisisi_moon_bigtts", "爽快思思"), v("zh_male_wennuanahu_moon_bigtts", "温暖阿虎"), v("zh_female_wanwanxiaohe_moon_bigtts", "湾湾小何"),
                    v("zh_male_beijingxiaoye_moon_bigtts", "北京小爷"), v("BV700_streaming", "灿灿"), v("BV001_streaming", "通用女声"), v("BV002_streaming", "通用男声")]
        }
    }
    var needsOwnKey: Bool { ![.system, .gateway].contains(self) }
    var needsRegion: Bool { self == .azure }
    var needsAppId: Bool { self == .volcengine }
    /// where to get a key
    var keyHelpURL: String? {
        switch self {
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .qwen: return "https://bailian.console.aliyun.com/?apiKey=1"
        case .azure: return "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices"
        case .elevenlabs: return "https://elevenlabs.io/app/settings/api-keys"
        case .minimax: return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .volcengine: return "https://console.volcengine.com/speech/app"
        default: return nil
        }
    }
    /// environment variables checked when no key is configured
    var envKeys: [String] {
        switch self {
        case .openai: return ["OPENAI_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .qwen: return ["DASHSCOPE_API_KEY"]
        case .azure: return ["AZURE_SPEECH_KEY", "SPEECH_KEY"]
        case .elevenlabs: return ["ELEVENLABS_API_KEY"]
        case .minimax: return ["MINIMAX_API_KEY"]
        case .volcengine: return ["VOLC_TTS_TOKEN"]
        default: return []
        }
    }
    /// can the request carry a speaking-style prompt
    var supportsStyle: Bool { [.gateway, .openai, .gemini].contains(self) }
}

struct VoiceOption: Hashable, Identifiable {
    let id: String
    let label: String
}

/// Per-provider editable TTS configuration fields shared by macOS and iOS Settings.
struct TTSFields: Equatable {
    var baseURL = "", key = "", model = "", voice = "", region = "", appId = ""
    var keyManaged = false
    static func load(_ p: TTSProvider) -> TTSFields {
        TTSFields(
            baseURL: Settings.ttsBaseURLOverride(p),
            key: p.needsOwnKey ? Settings.ttsKey(p) : "",
            model: Settings.ttsModel(p),
            voice: Settings.ttsVoice(p),
            region: Settings.ttsRegion,
            appId: Settings.ttsAppId,
            keyManaged: Settings.ttsKeyManagedByFile(p)
        )
    }
    func save(_ p: TTSProvider) {
        guard p.isRemote else { return }
        if p != .gateway { Settings.setTTSBaseURL(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), p) }
        if p.needsOwnKey, !keyManaged { Settings.setTTSKey(key.trimmingCharacters(in: .whitespacesAndNewlines), p) }
        if !model.isEmpty || p != .gateway { Settings.setTTSModel(model.trimmingCharacters(in: .whitespacesAndNewlines), p) }
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.setTTSVoice(trimmedVoice.isEmpty ? p.defaultVoice : trimmedVoice, p)
        if p.needsRegion { Settings.ttsRegion = region.trimmingCharacters(in: .whitespacesAndNewlines) }
        if p.needsAppId { Settings.ttsAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// macOS system speech, rendered to a WAV so caching, speed control, buffering and MP4 export work unchanged.
enum SystemTTS {
    /// BCP-47 code for the narration language (scripts are written in the translation target language)
    static func languageCode(_ target: String) -> String {
        switch target {
        case "简体中文": return "zh-CN"
        case "繁體中文": return "zh-TW"
        case "日本語": return "ja-JP"
        case "한국어": return "ko-KR"
        case "English": return "en-US"
        default:
            let t = target.lowercased()
            if t.contains("中文") || t.hasPrefix("zh") { return "zh-CN" }
            if t.hasPrefix("en") { return "en-US" }
            return Locale.preferredLanguages.first ?? "en-US"
        }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// installed voices for the language, best quality first (novelty and Personal Voice excluded).
    /// Cached for a minute: listing voices is not free and the UI asks often.
    nonisolated(unsafe) private static var voiceCache: [String: (at: Date, list: [AVSpeechSynthesisVoice])] = [:]
    private static let cacheLock = NSLock()
    static func voices(for target: String) -> [AVSpeechSynthesisVoice] {
        cacheLock.lock()
        if let c = voiceCache[target], Date().timeIntervalSince(c.at) < 60 { cacheLock.unlock(); return c.list }
        cacheLock.unlock()
        let list = loadVoices(for: target)
        cacheLock.lock(); voiceCache[target] = (Date(), list); cacheLock.unlock()
        return list
    }
    private static func loadVoices(for target: String) -> [AVSpeechSynthesisVoice] {
        let code = languageCode(target)
        let prefix = String(code.prefix { $0 != "-" })
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = all.filter { $0.language == code }
        let list = exact.isEmpty ? all.filter { $0.language.hasPrefix(prefix) } : exact
        return list.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = " · " + L("高级")
        case .enhanced: q = " · " + L("增强")
        default: q = ""
        }
        return "\(v.name)\(q) (\(v.language))"
    }

    static func options(for target: String) -> [VoiceOption] {
        voices(for: target).map { VoiceOption(id: $0.identifier, label: label($0)) }
    }

    /// chosen voice, or the best installed voice for the language when `id` is empty / not installed
    static func resolve(_ id: String, target: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices(for: target).first ?? AVSpeechSynthesisVoice(language: languageCode(target))
    }

    /// stable, filename-safe tag used in the audio cache
    static func cacheTag(_ id: String, target: String) -> String {
        let raw = resolve(id, target: target)?.identifier ?? languageCode(target)
        return "sys-" + String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" }).suffix(60)
    }

    /// synthesize at the natural rate (playback speed is applied by the player, like gateway audio)
    @MainActor
    static func synthesize(_ text: String, voiceId: String, target: String, speed: Float = 1) async throws -> Data {
        let u = AVSpeechUtterance(string: text)
        u.voice = resolve(voiceId, target: target)
        u.rate = utteranceRate(for: speed)
        u.prefersAssistiveTechnologySettings = false
        return try await withCheckedThrowingContinuation { c in
            SystemTTSJob().run(u, continuation: c)
        }
    }

    /// playback speed (1× = normal) → AVSpeechUtterance.rate (0…1, 0.5 = normal; not linear)
    static func utteranceRate(for speed: Float) -> Float {
        let table: [(Float, Float)] = [(0.5, 0.36), (0.75, 0.43), (1.0, 0.5), (1.25, 0.555), (1.5, 0.6), (1.75, 0.64), (2.0, 0.68), (2.5, 0.75), (3.0, 0.82)]
        let s = min(max(speed, table.first!.0), table.last!.0)
        for i in 1..<table.count where s <= table[i].0 {
            let (x0, y0) = table[i - 1], (x1, y1) = table[i]
            let r = y0 + (y1 - y0) * (s - x0) / (x1 - x0)
            return min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        }
        return AVSpeechUtteranceDefaultSpeechRate
    }

    /// quality of the best installed voice for the language (compact voices sound robotic)
    static func bestQuality(for target: String) -> AVSpeechSynthesisVoiceQuality {
        voices(for: target).first?.quality ?? .default
    }
    static var hasOnlyCompactVoices: Bool { bestQuality(for: Settings.targetLang) == .default }
    /// System Settings → Accessibility → Spoken Content (where Premium / Enhanced voices are downloaded)
    static let spokenContentSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!

    /// 16-bit mono PCM → WAV
    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

/// One utterance written to buffers. Keeps itself alive until finished; resumes the continuation exactly once.
private final class SystemTTSJob: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let q = DispatchQueue(label: "readit.system-tts")
    private var samples: [Int16] = []
    private var rate = 22050
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var keepAlive: SystemTTSJob?

    func run(_ u: AVSpeechUtterance, continuation c: CheckedContinuation<Data, Error>) {
        continuation = c
        keepAlive = self
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        synth.delegate = self
        synth.write(u) { [weak self] buf in self?.receive(buf) }
        q.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish() }   // safety net
    }

    private func receive(_ buf: AVAudioBuffer) {
        guard let pcm = buf as? AVAudioPCMBuffer else { return }
        let n = Int(pcm.frameLength)
        if n == 0 { q.async { self.finish() }; return }
        // copy synchronously: the buffer may be reused once the callback returns
        var chunk = [Int16](repeating: 0, count: n)
        if let f = pcm.floatChannelData {
            let p = f[0]
            for i in 0..<n { chunk[i] = Int16(max(-1, min(1, p[i])) * 32767) }
        } else if let s = pcm.int16ChannelData {
            let p = s[0]
            for i in 0..<n { chunk[i] = p[i] }
        } else if let s = pcm.int32ChannelData {
            let p = s[0]
            for i in 0..<n { chunk[i] = Int16(truncatingIfNeeded: p[i] >> 16) }
        } else { return }
        let r = Int(pcm.format.sampleRate)
        q.sync {
            rate = r > 0 ? r : rate
            samples.append(contentsOf: chunk)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        q.asyncAfter(deadline: .now() + 0.3) { self.finish() }    // let trailing buffers land first
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        q.async { self.finish() }
    }

    /// runs on `q`
    private func finish() {
        guard !finished else { return }
        finished = true
        let c = continuation; continuation = nil
        if samples.count > 1000 {
            c?.resume(returning: SystemTTS.wav(samples, rate: rate))
        } else {
            c?.resume(throwing: TranslateError.bad(L("系统语音合成失败：请在「系统设置 → 辅助功能 → 朗读内容」中确认已安装该语言的声音")))
        }
        DispatchQueue.main.async { self.keepAlive = nil }
    }
}
