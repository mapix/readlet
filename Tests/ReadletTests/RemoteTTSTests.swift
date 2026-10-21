import XCTest
@testable import Readlet

final class RemoteTTSTests: XCTestCase {
    func check(_ c: Bool, _ m: String, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(c, m, file: file, line: line) }
    func cfg(_ p: TTSProvider, base: String? = nil) -> TTSConfig { TTSConfig(provider: p, baseURL: base ?? p.defaultBaseURL, key: "K", model: p.defaultModel, voice: p.defaultVoice, region: "eastasia", appId: "APP", style: "warm", language: "Chinese") }
    func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }

    func testRequestsAndParsing() throws {
        var r = try! RemoteTTS.makeRequest(cfg(.openai, base: "https://api.openai.com/v1/"), text: "hi")
        check(r.url!.absoluteString == "https://api.openai.com/v1/audio/speech" && r.value(forHTTPHeaderField: "Authorization") == "Bearer K" && body(r)["instructions"] as? String == "warm" && body(r)["response_format"] as? String == "wav", "openai")
        var c = cfg(.openai); c.model = "tts-1"; r = try! RemoteTTS.makeRequest(c, text: "hi"); check(body(r)["instructions"] == nil, "tts-1 no instructions")
        r = try! RemoteTTS.makeRequest(cfg(.gemini), text: "你好")
        let gb = body(r); check(r.url!.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions" && r.value(forHTTPHeaderField: "x-goog-api-key") == "K", "gemini url/key")
        check(((gb["generation_config"] as? [String: Any])?["speech_config"] as? [[String: Any]])?.first?["voice"] as? String == "Zephyr", "gemini voice")
        r = try! RemoteTTS.makeRequest(cfg(.qwen), text: "你好")
        check(r.url!.absoluteString == "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation" && (body(r)["input"] as? [String: Any])?["voice"] as? String == "Cherry" && (body(r)["input"] as? [String: Any])?["language_type"] as? String == "Chinese", "qwen")
        c = cfg(.azure, base: "https://eastasia.tts.speech.microsoft.com"); r = try! RemoteTTS.makeRequest(c, text: "a<b & 'c'")
        let ss = String(data: r.httpBody!, encoding: .utf8)!
        check(r.url!.absoluteString.hasSuffix("/cognitiveservices/v1") && ss.contains("xml:lang='zh-CN'") && ss.contains("a&lt;b &amp; &apos;c&apos;") && r.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "riff-24khz-16bit-mono-pcm", "azure ssml")
        r = try! RemoteTTS.makeRequest(cfg(.elevenlabs), text: "x"); check(r.url!.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDXrnALMq?output_format=pcm_24000" && r.value(forHTTPHeaderField: "xi-api-key") == "K", "eleven")
        r = try! RemoteTTS.makeRequest(cfg(.minimax), text: "x"); check(r.url!.absoluteString == "https://api.minimaxi.com/v1/t2a_v2" && body(r)["output_format"] as? String == "hex", "minimax")
        r = try! RemoteTTS.makeRequest(cfg(.volcengine), text: "x"); check(r.value(forHTTPHeaderField: "Authorization") == "Bearer;K" && ((body(r)["app"] as? [String: Any])?["appid"] as? String) == "APP", "volc")
        // parsing
        let wav = Data("RIFF".utf8) + Data(count: 4) + Data("WAVE".utf8) + Data(count: 40)
        check(try! RemoteTTS.parse(.openai, data: wav, mimeType: "audio/wav") == .wav(wav), "openai wav")
        check((try? RemoteTTS.parse(.openai, data: Data("{\"error\":1}".utf8), mimeType: "application/json")) == nil, "openai json error")
        let b64 = wav.base64EncodedString()
        let gem = "{\"steps\":[{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"x\"},{\"type\":\"audio\",\"data\":\"\(b64)\"}]}]}"
        check(try! RemoteTTS.parse(.gemini, data: Data(gem.utf8), mimeType: "application/json") == .wav(wav), "gemini interactions")
        let gc = "{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/L16\",\"data\":\"AAAA\"}}]}}]}"
        check(try! RemoteTTS.parse(.gemini, data: Data(gc.utf8), mimeType: nil) == .pcm(Data([0,0,0]), rate: 24000), "gemini generateContent pcm")
        let qw = "{\"output\":{\"finish_reason\":\"stop\",\"audio\":{\"data\":\"\",\"url\":\"http://x.oss/a.wav?Expires=1\",\"id\":\"a\"}},\"usage\":{}}"
        check(try! RemoteTTS.parse(.qwen, data: Data(qw.utf8), mimeType: "application/json") == .url(URL(string: "http://x.oss/a.wav?Expires=1")!), "qwen url")
        let qe = "{\"code\":\"InvalidApiKey\",\"message\":\"bad key\"}"
        do { _ = try RemoteTTS.parse(.qwen, data: Data(qe.utf8), mimeType: nil); check(false, "qwen err") } catch let e as TranslateError { check(e == .http(400, "InvalidApiKey: bad key"), "qwen error code") } catch { check(false, "x") }
        let mm = "{\"data\":{\"audio\":\"49443303\",\"status\":2},\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}"
        check(try! RemoteTTS.parse(.minimax, data: Data(mm.utf8), mimeType: nil) == .encoded(Data([0x49,0x44,0x33,0x03]), ext: "mp3"), "minimax hex")
        let me = "{\"base_resp\":{\"status_code\":1002,\"status_msg\":\"rate limit\"}}"
        do { _ = try RemoteTTS.parse(.minimax, data: Data(me.utf8), mimeType: nil) } catch let e as TranslateError { check(e == .http(429, "MiniMax 1002: rate limit"), "minimax ratelimit→429") } catch {}
        let vc = "{\"reqid\":\"r\",\"code\":3000,\"message\":\"Success\",\"data\":\"\(b64)\"}"
        check(try! RemoteTTS.parse(.volcengine, data: Data(vc.utf8), mimeType: nil) == .wav(wav), "volc")
        check(try! RemoteTTS.parse(.elevenlabs, data: Data([1,2,3,4]), mimeType: "audio/pcm") == .pcm(Data([1,2,3,4]), rate: 24000), "eleven pcm")
        // chunks
        let long = String(repeating: "这是一个句子。", count: 120)
        let ch = RemoteTTS.chunks(long, max: 550)
        check(ch.allSatisfy { $0.count <= 550 } && ch.joined() == long, "chunks \(ch.count)")
        let huge = String(repeating: "啊", count: 1300)
        let ch2 = RemoteTTS.chunks(huge, max: 550); check(ch2.map { $0.count } == [550, 550, 200], "hard split")
        check(RemoteTTS.chunks("short", max: 10) == ["short"], "no split")
        check(Data(hexString: "00ff10") == Data([0, 255, 16]) && Data(hexString: "0g") == nil, "hex")
        check(RemoteTTS.trimmedBase("https://a.com/v1/") == "https://a.com", "trim v1")
        check(TTSProvider(configName: "dashscope") == .qwen && TTSProvider(configName: "doubao") == .volcengine && TTSProvider(configName: "openai_compatible") == .openai, "config names")
    }

    func testTTSFieldsAndCloudSettingsPayload() throws {
        // Verify all remote providers have preset voice suggestions
        for p in TTSProvider.allCases {
            if p.isRemote {
                check(!p.voiceSuggestions.isEmpty, "voiceSuggestions for \(p.rawValue)")
                check(!p.defaultVoice.isEmpty, "defaultVoice for \(p.rawValue)")
            } else {
                check(p.voiceSuggestions.isEmpty, "system voiceSuggestions empty")
            }
        }
        // Verify CloudSettingsPayload round-trips new optional voice & provider fields and remains backward-compatible
        let payload = CloudSync.CloudSettingsPayload(
            updatedAt: Date(timeIntervalSince1970: 1700000000),
            baseURL: "https://api.anthropic.com",
            model: "claude-haiku-5-5",
            translateModel: "claude-haiku-5-5",
            translateProtocol: "anthropic",
            assistantModel: "claude-haiku-5-5",
            assistantProtocol: "anthropic",
            targetLang: "简体中文",
            ttsProvider: TTSProvider.qwen.rawValue,
            ttsVoice: "Serena",
            ttsSpeed: 1.25,
            narrationStyle: NarrationStyle.deep.rawValue,
            narrationExtraPrompt: "Explain formulas",
            apiKey: nil,
            systemVoice: "com.apple.voice.premium.zh-CN.Tingting",
            ttsRegion: "eastasia",
            ttsAppId: "app123",
            providerVoices: ["qwen": "Serena", "openai": "nova"],
            providerModels: ["qwen": "qwen3-tts-flash"],
            providerBaseURLs: ["openai": "https://api.siliconflow.cn"]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudSync.CloudSettingsPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }
}
