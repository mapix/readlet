import Foundation

/// Resolved settings. Order: config file (`ConfigFile`) → legacy preferences (UserDefaults) → environment → default.
/// Setters always update the legacy preferences (so older builds keep working) and, if the config file
/// exists, write the value into it as well.
enum Settings {
    static var d: UserDefaults { .standard }
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var apiKey: String {
        get {
            if ConfigFile.keySource != .none, let k = ConfigFile.apiKey() { return k }
            // a key in preferences was written by an older build or `defaults write` (we delete it after
            // moving it), so it is newer than the Keychain copy: move it into the Keychain
            if let k = nonEmpty(d.string(forKey: "apiKey")) {
                if Keychain.store(k, "gateway") { d.removeObject(forKey: "apiKey") }
                return k
            }
            if let k = Keychain.cached("gateway") { return k }
            if let data = try? Data(contentsOf: Paths.base.appendingPathComponent("cloud-settings.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let k = nonEmpty(obj["apiKey"] as? String) {
                _ = Keychain.store(k, "gateway")
                return k
            }
            return nonEmpty(env["ANTHROPIC_AUTH_TOKEN"]) ?? nonEmpty(env["ANTHROPIC_API_KEY"]) ?? nonEmpty(env["OPENAI_API_KEY"]) ?? ""
        }
        set {
            // only touch the file if it already stores the key in plain text
            if ConfigFile.keySource == .file { ConfigFile.set(["gateway.api_key": .str(newValue)]); return }
            if Keychain.store(newValue, "gateway") { d.removeObject(forKey: "apiKey") }
            else { d.set(newValue, forKey: "apiKey") }          // Keychain unavailable: keep working
        }
    }
    /// the key is provided by the config file (env var / command) and cannot be edited in the Settings window
    static var apiKeyManagedByFile: Bool {
        switch ConfigFile.keySource { case .env, .command: return true; default: return false }
    }
    static var baseURL: String {
        get { ConfigFile.string("gateway.base_url") ?? nonEmpty(d.string(forKey: "baseURL")) ?? nonEmpty(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com" }
        set { d.set(newValue, forKey: "baseURL"); ConfigFile.set(["gateway.base_url": .str(newValue)]) }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? "claude-haiku-5-5" }
        set { d.set(newValue, forKey: "model") }
    }
    static var targetLang: String {
        get { ConfigFile.string("translate.target_language") ?? d.string(forKey: "targetLang") ?? "简体中文" }
        set { d.set(newValue, forKey: "targetLang"); ConfigFile.set(["translate.target_language": .str(newValue)]) }
    }
    /// pages translated ahead of the current one
    static var lookahead: Int {
        get { max(0, ConfigFile.int("translate.lookahead_pages") ?? d.object(forKey: "lookahead") as? Int ?? 2) }
        set { d.set(newValue, forKey: "lookahead"); ConfigFile.set(["translate.lookahead_pages": .int(newValue)]) }
    }
    /// TTS engine. Default is the macOS system voice; installs that already configured a gateway TTS model
    /// (legacy `model.tts` preference, or `tts.model` in the config file without `provider`) keep using the gateway.
    static var ttsProvider: TTSProvider {
        get {
            if let s = ConfigFile.string("tts.provider"), let p = TTSProvider(configName: s) { return p }
            if let s = d.string(forKey: "ttsProvider"), let p = TTSProvider(rawValue: s) { return p }
            if ConfigFile.string("tts.model") != nil || d.string(forKey: "model.tts") != nil { return .gateway }
            return .system
        }
        set { d.set(newValue.rawValue, forKey: "ttsProvider"); ConfigFile.set(["tts.provider": .str(newValue.rawValue)]) }
    }
    /// AVSpeechSynthesisVoice identifier; empty = best installed voice for the target language
    static var systemVoice: String {
        get { ConfigFile.values["tts.system_voice"] ?? d.string(forKey: "narrSystemVoice") ?? "" }
        set { d.set(newValue, forKey: "narrSystemVoice"); ConfigFile.set(["tts.system_voice": .str(newValue)]) }
    }
    /// AI Narration style preset (`[narration] style`)
    static var narrationStyle: NarrationStyle {
        get {
            if let s = ConfigFile.string("narration.style"), let v = NarrationStyle(configName: s) { return v }
            return d.string(forKey: "narrStyle").flatMap(NarrationStyle.init(rawValue:)) ?? .podcast
        }
        set { d.set(newValue.rawValue, forKey: "narrStyle"); ConfigFile.set(["narration.style": .str(newValue.rawValue)]) }
    }
    /// free-form extra instructions appended to the narration prompt (`[narration] extra_prompt`)
    static var narrationExtraPrompt: String {
        get { ConfigFile.values["narration.extra_prompt"] ?? d.string(forKey: "narrExtraPrompt") ?? "" }
        set { d.set(newValue, forKey: "narrExtraPrompt"); ConfigFile.set(["narration.extra_prompt": .str(newValue)]) }
    }
    /// voice of the active remote TTS provider
    static var ttsVoice: String {
        get { ttsVoice(ttsProvider) }
        set { setTTSVoice(newValue, ttsProvider) }
    }

    // MARK: per-provider TTS settings
    // The main-gateway provider keeps the original keys ([tts] model / voice, `model.tts`, `narrVoice`);
    // every other provider has its own config section, e.g. [tts.qwen] base_url / api_key… / model / voice.

    static func ttsSection(_ p: TTSProvider) -> String { "tts." + p.rawValue }

    static func ttsModel(_ p: TTSProvider) -> String {
        if p == .gateway { return ModelConfig.ttsModel }
        return ConfigFile.string(ttsSection(p) + ".model") ?? nonEmpty(d.string(forKey: "model.tts." + p.rawValue)) ?? p.defaultModel
    }
    static func setTTSModel(_ m: String, _ p: TTSProvider) {
        if p == .gateway { ModelConfig.setModel("tts", m); return }
        d.set(m, forKey: "model.tts." + p.rawValue); ConfigFile.set([ttsSection(p) + ".model": .str(m)])
    }

    static func ttsVoice(_ p: TTSProvider) -> String {
        if p == .gateway { return ConfigFile.string("tts.voice") ?? nonEmpty(d.string(forKey: "narrVoice")) ?? p.defaultVoice }
        return ConfigFile.string(ttsSection(p) + ".voice") ?? nonEmpty(d.string(forKey: "narrVoice." + p.rawValue)) ?? p.defaultVoice
    }
    static func setTTSVoice(_ v: String, _ p: TTSProvider) {
        if p == .gateway { d.set(v, forKey: "narrVoice"); ConfigFile.set(["tts.voice": .str(v)]); return }
        d.set(v, forKey: "narrVoice." + p.rawValue); ConfigFile.set([ttsSection(p) + ".voice": .str(v)])
    }

    /// user override only ("" = provider default)
    static func ttsBaseURLOverride(_ p: TTSProvider) -> String {
        ConfigFile.string(ttsSection(p) + ".base_url") ?? d.string(forKey: "tts.baseURL." + p.rawValue) ?? ""
    }
    static func setTTSBaseURL(_ u: String, _ p: TTSProvider) {
        d.set(u, forKey: "tts.baseURL." + p.rawValue); ConfigFile.set([ttsSection(p) + ".base_url": .str(u)])
    }
    /// effective base URL, without a trailing slash
    static func ttsBaseURL(_ p: TTSProvider) -> String {
        if p == .gateway { return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var u = nonEmpty(ttsBaseURLOverride(p)) ?? p.defaultBaseURL
        if p == .azure, u.isEmpty { u = "https://\(ttsRegion.isEmpty ? "eastus" : ttsRegion).tts.speech.microsoft.com" }
        return u.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func ttsKey(_ p: TTSProvider) -> String {
        if p == .gateway { return apiKey }
        let sec = ttsSection(p)
        if ConfigFile.keySource(for: sec) != .none, let k = ConfigFile.apiKey(for: sec) { return k }
        if let k = nonEmpty(d.string(forKey: "tts.key." + p.rawValue)) {
            if Keychain.store(k, sec) { d.removeObject(forKey: "tts.key." + p.rawValue) }
            return k
        }
        if let k = Keychain.cached(sec) { return k }
        if let data = try? Data(contentsOf: Paths.base.appendingPathComponent("cloud-settings.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pKeys = obj["providerKeys"] as? [String: String],
           let k = nonEmpty(pKeys[p.rawValue]) {
            _ = Keychain.store(k, sec)
            return k
        }
        for e in p.envKeys { if let k = nonEmpty(env[e]) { return k } }
        return ""
    }
    /// the key comes from the config file (env var / command) and can't be edited in the Settings window
    static func ttsKeyManagedByFile(_ p: TTSProvider) -> Bool {
        switch ConfigFile.keySource(for: ttsSection(p)) { case .env, .command: return true; default: return false }
    }
    static func setTTSKey(_ k: String, _ p: TTSProvider) {
        guard p.needsOwnKey else { return }
        let sec = ttsSection(p)
        if ConfigFile.keySource(for: sec) == .file { ConfigFile.set([sec + ".api_key": .str(k)]); return }
        if Keychain.store(k, sec) { d.removeObject(forKey: "tts.key." + p.rawValue) }
        else { d.set(k, forKey: "tts.key." + p.rawValue) }
    }

    /// system voice: synthesize at the narration speed instead of speeding up playback (more natural)
    static var systemNativeRate: Bool { (ConfigFile.string("tts.system_native_rate") ?? "true") != "false" }
    /// narration clip cache: "aac" (default, small) or "wav"
    static var ttsCacheFormat: String { (ConfigFile.string("tts.cache_format") ?? d.string(forKey: "tts.cacheFormat") ?? "aac").lowercased() }
    /// size cap for cached narration audio, in GB
    static var ttsCacheLimitGB: Double {
        get { ConfigFile.double("tts.cache_limit_gb") ?? (d.object(forKey: "tts.cacheLimitGB") as? Double) ?? 3 }
        set { d.set(newValue, forKey: "tts.cacheLimitGB"); ConfigFile.set(["tts.cache_limit_gb": .num(newValue)]) }
    }
    /// Azure Speech region, e.g. "eastasia"
    static var ttsRegion: String {
        get { ConfigFile.string("tts.azure.region") ?? d.string(forKey: "tts.region") ?? "" }
        set { d.set(newValue, forKey: "tts.region"); ConfigFile.set(["tts.azure.region": .str(newValue)]) }
    }
    /// Volcengine (豆包语音) application id
    static var ttsAppId: String {
        get { ConfigFile.string("tts.volcengine.app_id") ?? d.string(forKey: "tts.appId") ?? "" }
        set { d.set(newValue, forKey: "tts.appId"); ConfigFile.set(["tts.volcengine.app_id": .str(newValue)]) }
    }
    static var ttsSpeed: Float {
        get { ConfigFile.double("tts.speed").map { Float($0) } ?? d.object(forKey: "narrRate2") as? Float ?? 1.5 }
        set { d.set(newValue, forKey: "narrRate2"); ConfigFile.set(["tts.speed": .num(Double(newValue))]) }
    }

    /// snapshot used to create the config file from the current state (no API key)
    static var snapshot: [String: ConfigFile.Value] {
        [
            "gateway.base_url": .str(baseURL),
            "translate.model": .str(ModelConfig.translateModel),
            "translate.protocol": .str(ModelConfig.style("translate").configName),
            "translate.target_language": .str(targetLang),
            "translate.lookahead_pages": .int(lookahead),
            "assistant.model": .str(ModelConfig.chatModel),
            "assistant.protocol": .str(ModelConfig.style("chat").configName),
            "narration.style": .str(narrationStyle.rawValue),
            "narration.extra_prompt": .str(narrationExtraPrompt),
            "tts.provider": .str(ttsProvider.rawValue),
            "tts.system_voice": .str(systemVoice),
            "tts.model": .str(ModelConfig.ttsModel),
            "tts.voice": .str(ttsVoice),
            "tts.speed": .num(Double(ttsSpeed)),
        ]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}

enum TranslateError: LocalizedError, Equatable {
    case noKey, http(Int, String), bad(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return L("未设置 API Key（设置 → 通用 → 网关）")
        case .http(let c, let m):
            let hint: String
            switch c {
            case 401, 403: hint = L("请检查 API Key 和账号权限")
            case 404: hint = L("请检查 Base URL 和模型名称")
            case 408, 504: hint = L("请求超时，稍后再试")
            case 413: hint = L("内容太长，请减少页数后重试")
            case 429: hint = L("请求太多或额度不足，稍后再试")
            case 500...599: hint = L("服务暂时不可用，稍后再试")
            default: hint = ""
            }
            return "HTTP \(c)" + (hint.isEmpty ? "" : " · " + hint) + (m.isEmpty ? "" : "\n" + String(m.prefix(240)))
        case .bad(let m): return m
        }
    }
}

actor TranslationCache {
    static let shared = TranslationCache()
    private var map: [String: String] = [:]
    private var dirty = false
    private let url = Paths.base.appendingPathComponent("translations.json")
    init() {
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) { map = m }
    }
    func get(_ k: String) -> String? { map[k] }
    func set(_ k: String, _ v: String) {
        map[k] = v
        if !dirty { dirty = true; Task { try? await Task.sleep(nanoseconds: 400_000_000); self.flush() } }
    }
    func flush() {
        dirty = false
        if let d = try? JSONEncoder().encode(map) { try? d.write(to: url, options: .atomic) }
    }
    nonisolated func flushSync() {
        let sem = DispatchSemaphore(value: 0)
        Task { await self.flush(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }
}

enum Translator {
    static func key(_ text: String) -> String { ModelConfig.translateModel + "|" + Settings.targetLang + "|" + text }

    static func needsTranslation(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return letters >= 2 && Double(cjk) < Double(max(1, letters)) * 0.3
    }

    static func translateOne(_ text: String) async throws -> String {
        try await translate([text])[0]
    }

    /// translates a batch, using cache; preserves order
    static func translate(_ texts: [String]) async throws -> [String] {
        var out = [String?](repeating: nil, count: texts.count)
        var todo: [Int] = []
        for (i, t) in texts.enumerated() {
            if let c = await TranslationCache.shared.get(key(t)), !c.isEmpty { out[i] = c } else { todo.append(i) }
        }
        if !todo.isEmpty {
            let res = try await request(todo.map { texts[$0] })
            for (k, i) in todo.enumerated() {
                out[i] = res[k]
                await TranslationCache.shared.set(key(texts[i]), res[k])
            }
        }
        return out.map { $0 ?? "" }
    }

    nonisolated(unsafe) static var requestCount = 0
    private static func request(_ texts: [String]) async throws -> [String] {
        requestCount += 1
        let lang = Settings.targetLang
        let sys = """
        You are a professional academic translator. Translate every item of the JSON array the user sends into \(lang).
        Rules: precise, fluent, idiomatic \(lang); keep math, formulas, variable names, citations like [12], URLs, code, person names, emails, affiliations and proper nouns (model names, datasets) unchanged; PDF extraction may break words or include stray symbols, fix them silently; never add explanations.
        Output ONLY a JSON array of strings with exactly the same length and order as the input.
        """
        let input = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8)!
        var txt = try await LLMClient.complete(role: "translate", system: sys, input: LLMInput(text: input), maxTokens: 16000)
        txt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        if txt.hasPrefix("```") {
            txt = txt.replacingOccurrences(of: "^```(?:json)?\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        if let arr = parseArray(txt), arr.count == texts.count { return arr }
        if texts.count == 1 { return [txt] }
        let mid = texts.count / 2
        async let x = request(Array(texts[..<mid]))
        async let y = request(Array(texts[mid...]))
        return try await x + y
    }

    private static func parseArray(_ s: String) -> [String]? {
        func p(_ x: String) -> [String]? {
            guard let d = x.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
            return a.map { "\($0)" }
        }
        if let a = p(s) { return a }
        if let r = s.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression) { return p(String(s[r])) }
        return nil
    }
}
