import Foundation

extension TTSConfig {
    /// settings of a provider as currently configured
    static func current(_ p: TTSProvider) -> TTSConfig {
        TTSConfig(provider: p, baseURL: Settings.ttsBaseURL(p), key: Settings.ttsKey(p), model: Settings.ttsModel(p),
                  voice: Settings.ttsVoice(p), region: Settings.ttsRegion, appId: Settings.ttsAppId,
                  style: p.supportsStyle ? Narrator.styleInstruction : "", language: RemoteTTS.qwenLanguage(Settings.targetLang))
    }
}

extension RemoteTTS {
    /// problems retrying won't fix (no key, bad URL, unknown model/voice, 401/403/404…) → switch to the system voice
    static func isConfigError(_ e: Error) -> Bool {
        guard let t = e as? TranslateError else { return false }
        switch t {
        case .noKey: return true
        case .bad(let m): return !m.hasPrefix("TTS:")          // local validation (URL, voice, App ID); bad audio is retried
        case .http(let c, _): return [401, 403, 404].contains(c)
        }
    }

    /// text → clean 16-bit mono WAV; long text is split per provider limits and the pieces joined
    static func synthesize(_ text: String, _ c: TTSConfig, attempts: Int = 1) async throws -> Data {
        guard c.provider.isRemote else { throw TranslateError.bad("system voice is local") }
        try await MainActor.run { try AIConsent.ensure() }
        if c.key.isEmpty { throw TranslateError.noKey }
        if c.provider == .volcengine, c.appId.isEmpty { throw TranslateError.bad(L("火山引擎需要填写 App ID")) }
        if c.voice.isEmpty { throw TranslateError.bad(L("请填写音色")) }
        let pieces = chunks(text, max: maxChars(c.provider))
        var wavs: [Data] = []
        for piece in pieces { wavs.append(try await one(piece, c, attempts: attempts)) }
        UsageStore.shared.record(feature: "tts", model: c.provider.rawValue + "/" + c.model, input: text.count, output: 0, estimated: false)
        return wavs.count == 1 ? wavs[0] : concat(wavs)
    }

    private static func one(_ text: String, _ c: TTSConfig, attempts: Int) async throws -> Data {
        var last: Error = TranslateError.bad("TTS")
        let totalAttempts = max(1, attempts)
        for attempt in 0..<totalAttempts {
            try Task.checkCancellation()
            do {
                var req = try makeRequest(c, text: text)
                req.timeoutInterval = text.count < 90 ? 28 : 38
                let data: Data
                let resp: URLResponse
                if attempt == 0 {
                    (data, resp) = try await URLSession.shared.data(for: req)
                } else {
                    req.setValue("close", forHTTPHeaderField: "Connection")
                    let cfg = URLSessionConfiguration.ephemeral
                    cfg.timeoutIntervalForRequest = req.timeoutInterval
                    cfg.timeoutIntervalForResource = req.timeoutInterval + 5
                    let freshSession = URLSession(configuration: cfg)
                    defer { freshSession.finishTasksAndInvalidate() }
                    (data, resp) = try await freshSession.data(for: req)
                }
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if (200..<300).contains(code) {
                    let payload = try parse(c.provider, data: data, mimeType: http?.mimeType)
                    let wav = try await materialize(payload)
                    guard wav.count > 1000 else { throw TranslateError.bad("TTS: empty audio") }
                    return wav
                }
                last = TranslateError.http(code, String(data: data.prefix(300), encoding: .utf8) ?? "")
                if isConfigError(last) { throw last }
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                if isConfigError(error) { throw error }
                last = error
            }
            if attempt + 1 < totalAttempts {
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
        }
        throw last
    }

    private static func materialize(_ p: Payload) async throws -> Data {
        switch p {
        case .wav(let d):
            if let w = AudioCodec.toWAV(d, hint: "wav") { return w }
            throw TranslateError.bad("TTS: unreadable WAV")
        case .pcm(let d, let rate):
            return AudioCodec.wav(pcm16: d, rate: rate)
        case .encoded(let d, let ext):
            if let w = AudioCodec.toWAV(d, hint: ext) { return w }
            throw TranslateError.bad("TTS: unreadable audio")
        case .url(let u):
            let (d, resp) = try await URLSession.shared.data(from: u)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 300, let w = AudioCodec.toWAV(d, hint: u.pathExtension.lowercased()) else {
                throw TranslateError.bad("TTS: audio download failed")
            }
            return w
        }
    }

    /// join clips (resampled to the first clip's rate)
    static func concat(_ wavs: [Data]) -> Data {
        let pcms = wavs.compactMap { PCM(wav: $0) }
        guard let first = pcms.first else { return wavs.first ?? Data() }
        var all: [Int16] = []
        for p in pcms { all += p.rate == first.rate ? p.samples : p.resampled(to: first.rate) }
        return SystemTTS.wav(all, rate: first.rate)
    }
}
