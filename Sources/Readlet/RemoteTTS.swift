import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything a remote speech request needs (resolved from Settings for the active provider).
struct TTSConfig {
    var provider: TTSProvider
    var baseURL: String
    var key: String
    var model: String
    var voice: String
    var region = ""
    var appId = ""
    /// speaking-style prompt (sent to engines that accept one)
    var style = ""
    /// Qwen `language_type`, e.g. "Chinese"; "" = Auto
    var language = ""

}

/// Speech from hosted engines. Request building and response parsing are pure (unit-tested); `synthesize`
/// does the network calls and returns a clean 16-bit mono WAV.
enum RemoteTTS {
    enum Payload: Equatable {
        case wav(Data)                    // RIFF WAV
        case pcm(Data, rate: Int)         // headerless 16-bit LE mono
        case encoded(Data, ext: String)   // mp3 / m4a / … (decoded with AVFoundation)
        case url(URL)                     // audio to download (Qwen)
    }

    /// longest text per request; longer segments are split at sentence ends and the audio concatenated
    static func maxChars(_ p: TTSProvider) -> Int {
        switch p {
        case .qwen: return 550            // API limit 600
        case .volcengine: return 300      // API limit 1024 bytes UTF-8
        case .azure, .elevenlabs, .minimax: return 2500
        default: return 3000
        }
    }

    static func qwenLanguage(_ target: String) -> String {
        switch target {
        case "简体中文", "繁體中文": return "Chinese"
        case "English": return "English"
        case "日本語": return "Japanese"
        case "한국어": return "Korean"
        default: return "Auto"
        }
    }

    // MARK: requests

    static func trimmedBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
        return b
    }

    static func makeRequest(_ c: TTSConfig, text: String) throws -> URLRequest {
        func url(_ s: String) throws -> URL {
            guard let u = URL(string: s), u.scheme != nil else { throw TranslateError.bad("TTS base URL: " + s) }
            return u
        }
        func json(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
        let base = trimmedBase(c.baseURL)
        var req: URLRequest
        switch c.provider {
        case .system:
            throw TranslateError.bad("system voice is local")

        case .gateway, .openai:
            req = URLRequest(url: try url(base + "/v1/audio/speech"))
            req.setValue("Bearer " + c.key, forHTTPHeaderField: "Authorization")
            var b: [String: Any] = ["model": c.model, "input": text, "voice": c.voice, "response_format": "wav"]
            if !c.style.isEmpty, !c.model.hasPrefix("tts-1") { b["instructions"] = c.style }
            req.httpBody = try json(b)

        case .gemini:
            req = URLRequest(url: try url(base + "/v1beta/interactions"))
            req.setValue(c.key, forHTTPHeaderField: "x-goog-api-key")
            var item: [String: Any] = ["type": "text", "text": text]
            if !c.style.isEmpty { item["annotations"] = [["type": "speech_metadata", "style": c.style]] }
            req.httpBody = try json([
                "model": c.model,
                "input": [["type": "user_input", "content": [item]]],
                "response_format": ["type": "audio", "mime_type": "audio/wav"],
                "generation_config": ["speech_config": [["voice": c.voice]]],
            ])

        case .qwen:
            req = URLRequest(url: try url(base + "/api/v1/services/aigc/multimodal-generation/generation"))
            req.setValue("Bearer " + c.key, forHTTPHeaderField: "Authorization")
            var input: [String: Any] = ["text": text, "voice": c.voice]
            if !c.language.isEmpty { input["language_type"] = c.language }
            req.httpBody = try json(["model": c.model, "input": input])

        case .azure:
            req = URLRequest(url: try url(base + "/cognitiveservices/v1"))
            req.setValue(c.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            req.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
            req.setValue("riff-24khz-16bit-mono-pcm", forHTTPHeaderField: "X-Microsoft-OutputFormat")
            req.setValue("Readlet", forHTTPHeaderField: "User-Agent")
            req.httpBody = Data(ssml(text: text, voice: c.voice).utf8)

        case .elevenlabs:
            let v = c.voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.voice
            req = URLRequest(url: try url(base + "/v1/text-to-speech/\(v)?output_format=pcm_24000"))
            req.setValue(c.key, forHTTPHeaderField: "xi-api-key")
            req.httpBody = try json(["text": text, "model_id": c.model])

        case .minimax:
            req = URLRequest(url: try url(base + "/v1/t2a_v2"))
            req.setValue("Bearer " + c.key, forHTTPHeaderField: "Authorization")
            req.httpBody = try json([
                "model": c.model, "text": text, "stream": false, "output_format": "hex",
                "voice_setting": ["voice_id": c.voice, "speed": 1, "vol": 1, "pitch": 0],
                "audio_setting": ["sample_rate": 24000, "bitrate": 128000, "format": "mp3", "channel": 1],
            ])

        case .volcengine:
            req = URLRequest(url: try url(base + "/api/v1/tts"))
            req.setValue("Bearer;" + c.key, forHTTPHeaderField: "Authorization")
            req.httpBody = try json([
                "app": ["appid": c.appId, "token": c.key, "cluster": c.model.isEmpty ? "volcano_tts" : c.model],
                "user": ["uid": "readlet"],
                "audio": ["voice_type": c.voice, "encoding": "wav", "speed_ratio": 1.0],
                "request": ["reqid": UUID().uuidString, "text": text, "operation": "query"],
            ])
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 38
        if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    static func ssml(text: String, voice: String) -> String {
        // xml:lang from the voice name ("zh-CN-XiaoxiaoNeural" → "zh-CN")
        let parts = voice.split(separator: "-")
        let lang = parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "en-US"
        let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        let v = voice.replacingOccurrences(of: "'", with: "")
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(lang)'><voice name='\(v)'>\(esc)</voice></speak>"
    }

    // MARK: responses

    /// interpret a successful (2xx) response body
    static func parse(_ p: TTSProvider, data: Data, mimeType: String?) throws -> Payload {
        let mime = (mimeType ?? "").lowercased()
        func obj() throws -> [String: Any] {
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TranslateError.bad("TTS: unexpected response " + (String(data: data.prefix(160), encoding: .utf8) ?? ""))
            }
            return o
        }
        switch p {
        case .system:
            throw TranslateError.bad("system voice is local")

        case .gateway, .openai, .azure:
            if mime.contains("json") { throw TranslateError.http(400, String(data: data.prefix(300), encoding: .utf8) ?? "") }
            if data.count >= 12, data.prefix(4) == Data("RIFF".utf8) { return .wav(data) }
            if mime.contains("pcm") || mime.contains("l16") { return .pcm(data, rate: 24000) }
            return .encoded(data, ext: mime.contains("mpeg") || mime.contains("mp3") ? "mp3" : "")

        case .elevenlabs:
            if mime.contains("json") { throw TranslateError.http(400, String(data: data.prefix(300), encoding: .utf8) ?? "") }
            if mime.contains("mpeg") { return .encoded(data, ext: "mp3") }
            return .pcm(data, rate: 24000)

        case .gemini:
            let o = try obj()
            guard let b64 = geminiAudio(o), let audio = Data(base64Encoded: b64) else {
                throw TranslateError.http(400, "Gemini: no audio in response " + (String(data: data.prefix(200), encoding: .utf8) ?? ""))
            }
            return audio.prefix(4) == Data("RIFF".utf8) ? .wav(audio) : .pcm(audio, rate: 24000)

        case .qwen:
            let o = try obj()
            if let code = o["code"] as? String, !code.isEmpty { throw TranslateError.http(400, "\(code): \(o["message"] as? String ?? "")") }
            let audio = (o["output"] as? [String: Any])?["audio"] as? [String: Any]
            if let s = audio?["url"] as? String, let u = URL(string: s) { return .url(u) }
            if let b64 = audio?["data"] as? String, !b64.isEmpty, let d = Data(base64Encoded: b64) { return .pcm(d, rate: 24000) }
            throw TranslateError.http(400, "Qwen: no audio in response")

        case .minimax:
            let o = try obj()
            let br = o["base_resp"] as? [String: Any]
            let code = (br?["status_code"] as? NSNumber)?.intValue ?? 0
            if code != 0 {
                let msg = br?["status_msg"] as? String ?? "error"
                throw TranslateError.http([1002, 1039].contains(code) ? 429 : 400, "MiniMax \(code): \(msg)")
            }
            guard let hex = (o["data"] as? [String: Any])?["audio"] as? String, let d = Data(hexString: hex), !d.isEmpty else {
                throw TranslateError.http(400, "MiniMax: no audio in response")
            }
            return .encoded(d, ext: "mp3")

        case .volcengine:
            let o = try obj()
            let code = (o["code"] as? NSNumber)?.intValue ?? -1
            guard code == 3000, let b64 = o["data"] as? String, let d = Data(base64Encoded: b64) else {
                let msg = o["message"] as? String ?? "error"
                throw TranslateError.http([3003, 3005].contains(code) ? 429 : 400, "Volcengine \(code): \(msg)")
            }
            return d.prefix(4) == Data("RIFF".utf8) ? .wav(d) : .encoded(d, ext: "mp3")
        }
    }

    /// last audio block of an Interactions response (or a generateContent response)
    static func geminiAudio(_ o: [String: Any]) -> String? {
        var found: String?
        for step in (o["steps"] as? [[String: Any]]) ?? [] {
            for c in (step["content"] as? [[String: Any]]) ?? [] where (c["type"] as? String) == "audio" {
                if let d = c["data"] as? String { found = d }
            }
        }
        if found == nil, let oa = o["output_audio"] as? [String: Any] { found = oa["data"] as? String }
        if found == nil {
            for cand in (o["candidates"] as? [[String: Any]]) ?? [] {
                for part in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                    if let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any], let d = inline["data"] as? String { found = d }
                }
            }
        }
        return found
    }

    /// split long text at sentence ends so each piece fits the provider's limit
    static func chunks(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        var out: [String] = [], cur = ""
        let enders: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n", "，", ","]
        var sentence = ""
        func flush(_ s: String) {
            if cur.count + s.count > max, !cur.isEmpty { out.append(cur); cur = "" }
            if s.count > max {                         // a single huge sentence: hard split
                var rest = Substring(s)
                while rest.count > max { out.append(String(rest.prefix(max))); rest = rest.dropFirst(max) }
                cur = String(rest)
            } else { cur += s }
        }
        for ch in text {
            sentence.append(ch)
            if enders.contains(ch) { flush(sentence); sentence = "" }
        }
        if !sentence.isEmpty { flush(sentence) }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension Data {
    init?(hexString s: String) {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var d = Data(capacity: chars.count / 2)
        func v(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let h = v(chars[i]), let l = v(chars[i + 1]) else { return nil }
            d.append(h << 4 | l)
            i += 2
        }
        self = d
    }
}
