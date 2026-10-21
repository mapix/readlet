import Foundation
import AVFoundation
import PDFKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// "AI 解读" mode: for each page, Claude looks at the rendered page (text + figures) and writes a spoken-style
/// explanation split into short segments; each segment is synthesized with gemini-3.8-flash-tts and played,
/// then the reader auto-advances. Scripts and audio are cached per document so replays are instant and free.
@MainActor
final class Narrator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Narrator()

    struct Segment: Codable, Hashable { var text: String; var focus: String? }   // focus: short quote of what is being explained
    enum State: Equatable { case idle, preparing, playing, paused }

    @Published var state: State = .idle
    @Published var docId: UUID?
    @Published var page = 0
    @Published var segIndex = 0
    @Published var segments: [Segment] = []
    @Published var pageCount = 0
    @Published var error: String?
    /// raw WAV of the segment currently loaded (to rebuild the player when crossing the 2x limit)
    private var currentWav: Data?

    /// AVAudioPlayer tops out at 2x: above that, time-stretch the clip (pitch preserved) and play it at 2x
    /// system-voice clips are synthesized at the target speed (natural prosody) and played at 1×
    var nativeSpeed: Bool { effectiveProvider == .system && Settings.systemNativeRate }
    /// speed the player itself applies
    var playerRate: Float { nativeSpeed ? 1 : rate }

    func makePlayer(_ wav: Data) throws -> AVAudioPlayer {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let rate = playerRate
        var data = wav
        if rate > 2, let pcm = PCM(wav: wav) {
            data = Narrator.wavData(VideoComposer.timeStretch(pcm.samples, rate: pcm.rate, speed: rate / 2), rate: pcm.rate)
        }
        let pl = try AVAudioPlayer(data: data)
        pl.enableRate = true
        pl.rate = min(rate, 2)
        return pl
    }

    private func applyRate(old: Float) {
        if nativeSpeed {
            // the speed is baked into system-voice clips: upcoming clips are re-synthesized at the new speed
            if docId != nil, state != .idle { prefetch(page: page, from: segIndex + 1) }
            return
        }
        guard let pl = player else { return }
        if (old > 2) == (rate > 2) && rate <= 2 { pl.rate = rate; return }
        // crossing / within the stretched range: rebuild at the same relative position
        guard let wav = currentWav, let np = try? makePlayer(wav) else { pl.rate = min(rate, 2); return }
        let frac = pl.duration > 0 ? pl.currentTime / pl.duration : 0
        let wasPlaying = pl.isPlaying
        pl.delegate = nil; pl.stop()
        np.delegate = self
        np.currentTime = frac * np.duration
        player = np
        if wasPlaying { np.play() }
    }

    static func wavData(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    @Published var rate: Float = Settings.ttsSpeed {
        didSet { if rate != oldValue { Settings.ttsSpeed = rate }; applyRate(old: oldValue) }
    }
    /// voice of the active remote TTS provider
    @Published var voice: String = Settings.ttsVoice {
        didSet { if voice != oldValue { Settings.ttsVoice = voice; refreshBuffered() } }
    }
    /// TTS engine and macOS voice (identifier; "" = automatic)
    @Published var provider: TTSProvider = Settings.ttsProvider {
        didSet {
            guard provider != oldValue else { return }
            Settings.ttsProvider = provider; fallbackToSystem = false
            voice = Settings.ttsVoice(provider)                   // each provider remembers its own voice
            refreshBuffered()
        }
    }
    @Published var systemVoice: String = Settings.systemVoice {
        didSet { if systemVoice != oldValue { Settings.systemVoice = systemVoice; refreshBuffered() } }
    }
    /// set for the current run when the gateway rejects TTS requests (no TTS model, bad key…)
    @Published var fallbackToSystem = false
    @Published var fallbackReason = ""
    var effectiveProvider: TTSProvider { fallbackToSystem ? .system : provider }
    /// part of the audio cache filename, so clips from different engines / voices / script styles never mix
    var voiceTag: String {
        let p = effectiveProvider
        let engine: String
        switch p {
        case .system: engine = SystemTTS.cacheTag(systemVoice, target: Settings.targetLang) + (nativeSpeed ? "-r\(Int((rate * 100).rounded()))" : "")
        case .gateway: engine = voice                                                  // original cache names
        default:
            let id = p.rawValue + "|" + voice + "|" + Settings.ttsModel(p) + "|" + Settings.ttsBaseURL(p)
            engine = p.rawValue + "-" + String(voice.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(40)) + NarrationStyle.hash(id)
        }
        return engine + scriptSuffix
    }
    /// "" for the default narration style (original cache names), else a per-style suffix
    var scriptSuffix: String { NarrationStyle.cacheSuffix(style: Settings.narrationStyle, extra: Settings.narrationExtraPrompt) }
    func scriptFileName(_ p: Int) -> String { "p\(p)\(scriptSuffix).json" }
    func scriptURL(_ p: Int, docId: UUID? = nil) -> URL { cacheDir(for: docId).appendingPathComponent(scriptFileName(p)) }
    /// entries for the voice menus
    var voiceOptions: [VoiceOption] {
        let p = effectiveProvider
        if p.isRemote {
            var list = p.voiceSuggestions
            if !voice.isEmpty, !list.contains(where: { $0.id == voice }) { list.insert(VoiceOption(id: voice, label: voice), at: 0) }
            return list
        }
        return [VoiceOption(id: "", label: L("自动（按目标语言）"))] + SystemTTS.options(for: Settings.targetLang)
    }
    var currentVoiceID: String { effectiveProvider.isRemote ? voice : systemVoice }
    var currentVoiceName: String {
        let p = effectiveProvider
        if p.isRemote {
            let label = p.voiceSuggestions.first { $0.id == voice }?.label ?? voice
            return String(label.split(separator: "·").first ?? Substring(label)).trimmingCharacters(in: .whitespaces)
        }
        return SystemTTS.resolve(systemVoice, target: Settings.targetLang)?.name ?? L("系统语音")
    }
    func selectVoice(_ id: String) {
        if effectiveProvider.isRemote { voice = id } else { systemVoice = id }
        CloudSync.shared.recordSettingsChange()
    }
    func selectProvider(_ p: TTSProvider) {
        fallbackToSystem = false
        fallbackReason = ""
        if provider != p {
            provider = p
        } else {
            voice = Settings.ttsVoice(p)
            refreshBuffered()
        }
        CloudSync.shared.recordSettingsChange()
    }
    static let voices = ["Zephyr", "Leda", "Aoede", "Kore", "Puck", "Charon", "Fenrir", "Orus"]
    static let voiceNames = ["Leda": "Leda · 年轻轻松女声", "Aoede": "Aoede · 温柔女声", "Kore": "Kore · 沉稳女声", "Zephyr": "Zephyr · 明亮女声", "Puck": "Puck · 活泼男声", "Charon": "Charon · 知性男声", "Fenrir": "Fenrir · 激昂男声", "Orus": "Orus · 低沉男声"]
    nonisolated static let styleInstruction = "用年轻、轻松、亲切的语气朗读，像和朋友聊天一样自然，语调有起伏，不要播音腔。"
    /// reader of the window showing the narrated document
    static var reader: ReaderController { DocWindows.shared.entries[shared.docId ?? UUID()]?.reader ?? ReaderController.shared }

    private var player: AVAudioPlayer?
    private var doc: PDFDocument?
    /// original (untranslated) document used to build scripts, regardless of the view mode
    private var sourceDoc: PDFDocument?
    private var title = ""
    /// document being narrated (original or bilingual variant) and its title — used by the MP4 export
    var narratedDoc: PDFDocument? { doc }
    var narratedTitle: String { title }

    /// "录制": off by default. While on, remember which (page, segment) were played. The export itself is always
    /// a clean full pass built from cached assets; this only reports coverage.
    @Published var recording = false { didSet { if recording && !oldValue { recorded = [] } } }
    @Published var recorded: Set<String> = []
    private var runToken = UUID()
    private var scriptTasks: [String: Task<[Segment], Error>] = [:]     // "page+style suffix"
    private var audioTasks: [String: Task<Data, Error>] = [:]

    var progress: Double {
        guard pageCount > 0 else { return 0 }
        let inPage = segments.isEmpty ? 0 : Double(segIndex) / Double(segments.count)
        return (Double(page) + inPage) / Double(pageCount)
    }

    // MARK: remaining-time estimate

    /// script length (characters) per page, from the cached scripts; pages not scripted yet are estimated
    var pageChars: [Int: Int] = [:]
    var pageCharsMissing: Set<Int> = []

    private var pageCharsSuffix = ""
    private func chars(ofPage p: Int) -> Int? {
        let sfx = scriptSuffix
        if sfx != pageCharsSuffix { pageCharsSuffix = sfx; pageChars = [:]; pageCharsMissing = [] }
        if let c = pageChars[p] { return c }
        if pageCharsMissing.contains(p) { return nil }
        let u = scriptURL(p)
        if let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([Segment].self, from: d) {
            let c = s.reduce(0) { $0 + $1.text.count }
            pageChars[p] = c
            return c
        }
        pageCharsMissing.insert(p)
        return nil
    }

    /// seconds of audio per character at 1×, learned from synthesized clips (per target language)
    static var paceKey: String { "narrPace." + shared.effectiveProvider.rawValue + "." + Settings.targetLang }
    static var pace: Double {
        if let a = UserDefaults.standard.array(forKey: paceKey) as? [Double], a.count == 2, a[0] > 200, a[1] > 0 {
            return a[1] / a[0]
        }
        // defaults: CJK speech ≈ 4.5 chars/s, alphabetic ≈ 14 chars/s
        let l = Settings.targetLang
        return (l.contains("中文") || l.contains("日本") || l.contains("한국")) ? 0.22 : 0.072
    }
    private var paceSeen: Set<String> = []
    private func learnPace(key: String, text: String, wav: Data) {
        guard !paceSeen.contains(key), let secs = Narrator.wavSeconds(wav), secs > 0.3, text.count > 4 else { return }
        paceSeen.insert(key)
        var a = UserDefaults.standard.array(forKey: Narrator.paceKey) as? [Double] ?? [0, 0]
        if a.count != 2 { a = [0, 0] }
        a[0] += Double(text.count); a[1] += secs * Double(nativeSpeed ? rate : 1)    // pace is kept on a 1× basis
        if a[1] > 3600 { a = a.map { $0 / 2 } }      // keep adapting to recent voices
        UserDefaults.standard.set(a, forKey: Narrator.paceKey)
    }
    static func wavSeconds(_ d: Data) -> Double? {
        guard d.count > 44 else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 }
        let byteRate = u32(28), ch = u16(22), bits = u16(34)
        guard byteRate > 0, ch > 0, bits > 0 else { return nil }
        return Double(d.count - 44) / Double(byteRate)
    }

    /// estimated real time (seconds, at the current speed) to finish the document from the current position
    func remainingSeconds() -> Double? {
        guard docId != nil, pageCount > 0, state != .idle else { return nil }
        let speed = Double(max(0.25, rate))
        let pace = Narrator.pace
        var seconds = 0.0
        var n = 0                       // characters still to be spoken on known scripts
        var unknownPages = 0
        if segments.isEmpty {
            if let c = chars(ofPage: page) { n += c } else { unknownPages += 1 }
        } else {
            if segIndex < segments.count {
                if let pl = player, state == .playing || state == .paused, pl.duration > 0 {
                    seconds += max(0, pl.duration - pl.currentTime) / Double(max(0.25, pl.rate))
                } else {
                    n += segments[segIndex].text.count
                }
            }
            if segIndex + 1 < segments.count {
                n += segments[(segIndex + 1)...].reduce(0) { $0 + $1.text.count }
            }
        }
        // following pages: cached scripts where available, the average scripted page otherwise
        if page + 1 < pageCount {
            for p in (page + 1)..<pageCount {
                if let c = chars(ofPage: p) { n += c } else { unknownPages += 1 }
            }
        }
        let scripted = pageChars.values
        let avg = scripted.isEmpty ? 420.0 : Double(scripted.reduce(0, +)) / Double(scripted.count)
        let totalChars = Double(n) + avg * Double(unknownPages)
        seconds += totalChars * pace / speed
        return seconds
    }

    /// "剩余约 1 小时 5 分" / "about 1 h 5 min left"
    static func formatRemaining(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if m < 1 { return L("剩余不到 1 分钟") }
        if m < 60 { return LF("剩余约 %d 分钟", m) }
        return LF("剩余约 %d 小时 %d 分", m / 60, m % 60)
    }
    /// short form for compact UIs: "≈12m" / "≈1h05m"
    static func formatRemainingShort(_ s: Double) -> String {
        let m = max(1, Int((s / 60).rounded()))
        return m < 60 ? "≈\(m)m" : String(format: "≈%dh%02dm", m / 60, m % 60)
    }

    // MARK: control

    /// start narrating; resumes from saved segment if on the same page (or if starting from page 0 with saved progress),
    /// otherwise starts from the current reader page `page` so opening/scrolling to a page never jumps back to page 0.
    func start(docId: UUID, doc: PDFDocument, title: String, from page: Int, resume: Bool = true) {
        stop()
        // pick up hand edits of config.toml since launch
        let v = Settings.ttsVoice, r = Settings.ttsSpeed, pr = Settings.ttsProvider, sv = Settings.systemVoice
        if voice != v { voice = v }
        if rate != r { rate = r }
        if provider != pr { provider = pr }
        if systemVoice != sv { systemVoice = sv }
        fallbackToSystem = false
        if self.docId != docId { pageChars = [:]; pageCharsMissing = [] }
        self.docId = docId; self.doc = doc; self.title = title
        sourceDoc = Store.shared.session(docId)?.original
        pageCount = doc.pageCount
        error = nil
        guard pageCount > 0 else { return }
        let targetPage = max(0, min(pageCount - 1, page))
        if resume, let s = Narrator.savedProgress(docId), s.page >= 0, s.page < pageCount {
            if s.page == targetPage && s.seg > 0 {
                resumedFrom = s
                play(page: s.page, seg: s.seg)
                return
            } else if targetPage == 0 && (s.page > 0 || s.seg > 0) {
                resumedFrom = s
                play(page: s.page, seg: max(0, s.seg))
                return
            }
        }
        resumedFrom = nil
        play(page: targetPage, seg: 0)
    }

    /// ignore the saved position and start at the page currently shown in the reader (from segment 0)
    func restartFromCurrentPage() {
        guard let id = docId, let d = doc else { return }
        let curPage = Narrator.reader.currentPageIndex
        Narrator.clearProgress(id)
        start(docId: id, doc: d, title: title, from: curPage, resume: false)
    }

    // MARK: persisted progress (per document, voice independent, synced across Mac & iOS)
    struct Progress: Codable, Equatable { var page: Int; var seg: Int; var date: Date = Date() }
    /// set when the current run resumed from a saved position (shown in the bar)
    @Published var resumedFrom: Progress?
    nonisolated static func progressURL(_ id: UUID) -> URL {
        let u = Paths.docDir(id).appendingPathComponent("narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("progress.json")
    }
    nonisolated static func savedDiskProgress(_ id: UUID) -> Progress? {
        guard let d = try? Data(contentsOf: progressURL(id)) else { return nil }
        return try? JSONDecoder().decode(Progress.self, from: d)
    }
    static func savedProgress(_ id: UUID) -> Progress? {
        let disk = savedDiskProgress(id)
        let docProg: Progress? = {
            guard let doc = Store.shared.doc(id), let np = doc.narrationPage else { return nil }
            return Progress(page: np, seg: doc.narrationSeg ?? 0, date: doc.narrationUpdatedAt ?? doc.updatedAt ?? .distantPast)
        }()
        switch (disk, docProg) {
        case (let a?, let b?):
            let aNonZero = a.page > 0 || a.seg > 0
            let bNonZero = b.page > 0 || b.seg > 0
            if aNonZero && !bNonZero { return a }
            if bNonZero && !aNonZero { return b }
            return b.date > a.date ? b : a
        case (let a?, nil):
            return a
        case (nil, let b?):
            return b
        case (nil, nil):
            return nil
        }
    }
    static func saveProgress(_ id: UUID, page: Int, seg: Int) {
        let now = Date()
        let p = Progress(page: page, seg: seg, date: now)
        if let d = try? JSONEncoder().encode(p) {
            try? d.write(to: progressURL(id), options: .atomic)
        }
        Store.shared.updateNarrationProgress(docId: id, page: page, seg: seg, date: now)
    }
    static func clearProgress(_ id: UUID) {
        try? FileManager.default.removeItem(at: progressURL(id))
        Store.shared.clearNarrationProgress(docId: id)
    }

    func togglePause() {
        switch state {
        case .playing: player?.pause(); state = .paused
        case .paused:
            if let p = player {
                if segIndex < segments.count {
                    Narrator.reader.highlightNarration(page: page, quote: segments[segIndex].focus)
                }
                p.play()
                state = .playing
            } else { play(page: page, seg: segIndex) }
        default: break
        }
    }

    func stop() {
        runToken = UUID()
        prefetchToken = UUID()
        prefetchTask?.cancel()
        prefetchTask = nil
        for t in scriptTasks.values { t.cancel() }
        scriptTasks.removeAll()
        for t in audioTasks.values { t.cancel() }
        audioTasks.removeAll()
        while !systemQueue.isEmpty {
            let r = systemQueue.removeFirst()
            r.cont.resume(throwing: CancellationError())
        }
        systemBusy = false
        qaPlayer?.stop(); qaPlayer = nil
        if listening { listening = false; VoiceInput.shared.stop { _ in } }
        player?.stop(); player = nil
        state = .idle
        segments = []; segIndex = 0
    }

    func next() { guard state != .idle else { return }; advance() }
    func previous() {
        guard state != .idle else { return }
        if segIndex > 0 { play(page: page, seg: segIndex - 1) }
        else if page > 0 { play(page: page - 1, seg: -1) }
    }
    func jumpToSegment(_ i: Int) { guard docId != nil, i < segments.count else { return }; play(page: page, seg: i) }
    func jump(page p: Int) { guard docId != nil else { return }; play(page: max(0, min(pageCount - 1, p)), seg: 0) }
    /// "从这页开始讲": continue the narration from the page the reader is showing now
    func narrateFromReaderPage() {
        guard docId != nil, state != .idle else { return }
        resumedFrom = nil
        jump(page: Narrator.reader.currentPageIndex)
    }

    // MARK: voice Q&A (interrupt narration)
    @Published var listening = false
    @Published var heard = ""
    @Published var answering = false
    @Published var lastQA: (q: String, a: String)?
    private var resumeAfterQA = false
    private var qaPlayer: AVAudioPlayer?

    func beginQuestion() {
        guard !listening else { return }
        resumeAfterQA = state == .playing
        if state == .playing { player?.pause(); state = .paused }
        qaPlayer?.stop()
        heard = ""
        listening = true
        VoiceInput.shared.start { [weak self] partial in self?.heard = partial }
    }

    func endQuestion() {
        guard listening else { return }
        listening = false
        VoiceInput.shared.stop { [weak self] final in
            guard let self else { return }
            let q = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { if self.resumeAfterQA { self.togglePause() }; return }
            self.heard = q
            self.answer(q)
        }
    }

    func debugAsk(_ q: String) { resumeAfterQA = state == .playing; if state == .playing { player?.pause(); state = .paused }; heard = q; answer(q) }

    private func answer(_ q: String) {
        guard let doc = sourceDoc ?? doc, let pg = doc.safePage(page) else { return }
        answering = true
        let seg = segIndex < segments.count ? segments[segIndex].text : ""
        let sys = "你是正在给用户语音讲解《\(title)》的讲解员，用户在听讲过程中打断你提问。用\(Settings.targetLang)口语回答，简洁清楚（3–6 句话，适合朗读，不要用列表和符号），回答完自然地说一句「我们继续」。"
        let ctx = "当前第 \(page + 1) 页。你刚才讲到：\(seg)\n\n本页原文：\(pg.string ?? "")\n\n用户的问题：\(q)"
        let img = Narrator.jpeg(of: pg)
        Task {
            do {
                let a = try await LLMClient.complete(role: "chat", system: sys, input: LLMInput(text: ctx, images: [img]), maxTokens: 800, feature: "narration")
                lastQA = (q, a)
                if let id = docId { CopilotStore.shared.record(docId: id, question: q, answer: a, page: page) }
                let wav = try await synth(a)
                answering = false
                let pl = try makePlayer(wav)
                pl.delegate = self
                qaPlayer = pl
                pl.play()
            } catch {
                answering = false
                self.error = error.localizedDescription
            }
        }
    }

    /// one-off synthesis (not cached per segment)
    private func synth(_ text: String) async throws -> Data {
        if effectiveProvider == .system { return try await systemSynth(text, urgent: true) }
        do { return try await RemoteTTS.synthesize(text, TTSConfig.current(provider)) }
        catch let e as TranslateError where RemoteTTS.isConfigError(e) {
            fallbackToSystem = true; fallbackReason = e.errorDescription ?? ""
            return try await systemSynth(text, urgent: true)
        }
    }

    /// Settings → "试听": synthesize a short sample with the selected engine (no automatic fallback) and play it
    func previewVoice() async throws {
        let sample = Settings.targetLang.contains("English") ? "Hi, this is how narration will sound in Readlet." : (Settings.targetLang.contains("日本") ? "こんにちは。Readlet の解説はこの声で読み上げます。" : "你好，这是 Readlet 讲解时会用到的声音。")
        let wav: Data
        if provider.isRemote { wav = try await RemoteTTS.synthesize(sample, TTSConfig.current(provider)) }
        else { wav = try await systemSynth(sample, urgent: true) }
        resumeAfterQA = false
        let pl = try makePlayer(wav)
        qaPlayer?.stop()
        pl.delegate = self
        qaPlayer = pl
        pl.play()
    }

    /// macOS voices: one utterance at a time; the clip playback is waiting for goes first
    private struct SystemRequest {
        let text: String, voice: String, lang: String, speed: Float
        let cont: CheckedContinuation<Data, Error>
    }
    private var systemQueue: [SystemRequest] = []
    private var systemBusy = false
    private func systemSynth(_ text: String, urgent: Bool = false) async throws -> Data {
        let vid = systemVoice, lang = Settings.targetLang
        return try await withCheckedThrowingContinuation { c in
            let r = SystemRequest(text: text, voice: vid, lang: lang, speed: nativeSpeed ? rate : 1, cont: c)
            if urgent { systemQueue.insert(r, at: 0) } else { systemQueue.append(r) }
            pumpSystem()
        }
    }
    private func promoteSystem(_ text: String) {
        guard let i = systemQueue.firstIndex(where: { $0.text == text }), i > 0 else { return }
        systemQueue.insert(systemQueue.remove(at: i), at: 0)
    }
    private func pumpSystem() {
        guard !systemBusy, !systemQueue.isEmpty else { return }
        systemBusy = true
        let r = systemQueue.removeFirst()
        Task { @MainActor in
            do {
                let d = try await SystemTTS.synthesize(r.text, voiceId: r.voice, target: r.lang, speed: r.speed)
                r.cont.resume(returning: d)
            } catch { r.cont.resume(throwing: error) }
            self.systemBusy = false
            self.pumpSystem()
        }
    }

    // MARK: engine

    private func play(page p: Int, seg: Int) {
        let token = UUID(); runToken = token
        // Cancel background prefetch so the current segment gets immediate network priority
        prefetchToken = UUID()
        prefetchTask?.cancel()
        prefetchTask = nil
        player?.stop(); player = nil
        error = nil
        page = p
        state = .preparing
        if Narrator.reader.currentPageIndex != p && Narrator.reader.focusedNarrationPage != p {
            Narrator.reader.goToPage(p)
        }
        if let cached = cachedScript(p), !ScriptParser.looksBroken(cached.map(\.text)), !cached.isEmpty {
            segments = cached
            segIndex = seg < 0 ? cached.count - 1 : min(seg, cached.count - 1)
        } else {
            segments = []
            segIndex = 0
        }
        Task {
            do {
                let segs = try await script(for: p)
                guard token == runToken else { return }
                segments = segs
                if segs.isEmpty { advancePage(); return }
                let i = seg < 0 ? segs.count - 1 : min(seg, segs.count - 1)
                segIndex = i
                if let id = docId { Narrator.saveProgress(id, page: p, seg: i) }
                let t = segs[i].text
                Narrator.reader.segmentMentionsFigure = t.range(of: "(图|表|横轴|纵轴|曲线|柱状|折线|示意|figure|table)", options: [.regularExpression, .caseInsensitive]) != nil
                Narrator.reader.highlightNarration(page: p, quote: segs[i].focus)
                // Synthesize the urgent current segment FIRST before starting look-ahead prefetch
                let wav = try await audio(page: p, seg: i, text: segs[i].text, urgent: true)
                guard token == runToken else { return }
                let pl = try makePlayer(wav)
                pl.delegate = self
                currentWav = wav
                player = pl
                state = .playing
                Narrator.reader.highlightNarration(page: p, quote: segs[i].focus)
                if recording { recorded.insert("\(p)-\(i)") }
                pl.play()
                // Start look-ahead buffering only after the current segment is actively playing
                prefetch(page: p, from: i + 1)
            } catch is CancellationError {
                return
            } catch {
                guard token == runToken else { return }
                self.error = error.localizedDescription
                state = .paused
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === p { self.advance() }
            else if self.qaPlayer === p {
                self.qaPlayer = nil
                if self.resumeAfterQA, self.state == .paused { self.player?.play(); self.state = .playing }
            }
        }
    }

    private func advance() {
        if segIndex + 1 < segments.count { play(page: page, seg: segIndex + 1) } else { advancePage() }
    }

    private func advancePage() {
        if page + 1 < pageCount { play(page: page + 1, seg: 0) }
        else {
            if let id = docId { Narrator.clearProgress(id) }     // finished the document: next start begins fresh
            stop(); resumedFrom = nil; Narrator.reader.clearNarrationHighlight()
        }
    }

    // MARK: look-ahead
    //
    // Two independent pipelines so playback rarely waits:
    //  • scripts: the next `scriptPagesAhead` pages are written in parallel as soon as a page starts;
    //  • audio: everything already scripted is synthesized up to `bufferSeconds` of listening time
    //    (at the current speed; at least `minBufferSegments`, at most `maxBufferSegments`), with a sliding
    //    window of requests in flight. It never blocks on a script that is still being written — when that
    //    script lands, the audio plan is extended.

    /// listening time to keep synthesized ahead (seconds at the current speed); `tts.buffer_seconds`
    static var bufferSeconds: Double { Double(max(30, ConfigFile.int("tts.buffer_seconds") ?? UserDefaults.standard.object(forKey: "narrBufferSeconds") as? Int ?? 300)) }
    /// pages whose scripts are prepared ahead; `tts.script_pages_ahead`
    static var scriptPagesAhead: Int { max(1, min(10, ConfigFile.int("tts.script_pages_ahead") ?? UserDefaults.standard.object(forKey: "narrScriptPagesAhead") as? Int ?? 3)) }
    static let minBufferSegments = 12
    static let maxBufferSegments = 60
    /// kept for the UI counter
    static var bufferAhead: Int { maxBufferSegments }
    private var prefetchToken = UUID()
    private var prefetchTask: Task<Void, Never>?

    /// what "全部准备" still has to generate (for the confirmation estimate)
    struct PreparePlan { var pages = 0; var missingScripts = 0; var missingChars = 0 }
    func preparePlan() -> PreparePlan {
        var plan = PreparePlan(pages: pageCount)
        let tag = voiceTag
        let scripted = pageChars.values
        let avg = scripted.isEmpty ? 420 : scripted.reduce(0, +) / scripted.count
        for p in 0..<pageCount {
            if let segs = cachedScript(p) {
                for (i, sg) in segs.enumerated() where !hasClip(page: p, seg: i, tag: tag) { plan.missingChars += sg.text.count }
            } else {
                plan.missingScripts += 1; plan.missingChars += avg
            }
        }
        return plan
    }

    private func cachedScript(_ p: Int, docId: UUID? = nil) -> [Segment]? {
        guard let d = try? Data(contentsOf: scriptURL(p, docId: docId)) else { return nil }
        return try? JSONDecoder().decode([Segment].self, from: d)
    }
    // MARK: clip cache — AAC (.m4a) since 0.2; WAV clips from older builds are still read

    private func clipStem(_ p: Int, _ i: Int, tag: String) -> String { "p\(p)-s\(i)-\(tag)" }
    private func clipURLs(_ p: Int, _ i: Int, tag: String, docId: UUID? = nil) -> (m4a: URL, wav: URL) {
        let d = cacheDir(for: docId), stem = clipStem(p, i, tag: tag)
        return (d.appendingPathComponent(stem + "-v3.m4a"), d.appendingPathComponent(stem + "-v2.wav"))
    }
    func hasClip(page p: Int, seg i: Int, tag: String, docId: UUID? = nil) -> Bool {
        let u = clipURLs(p, i, tag: tag, docId: docId)
        return FileManager.default.fileExists(atPath: u.m4a.path) || FileManager.default.fileExists(atPath: u.wav.path)
    }
    /// cached clip as a clean WAV (decoded from AAC when needed)
    func clipData(page p: Int, seg i: Int, tag: String, docId: UUID? = nil) -> Data? {
        let u = clipURLs(p, i, tag: tag, docId: docId)
        if FileManager.default.fileExists(atPath: u.m4a.path) {
            if let w = AudioCodec.decodeFile(u.m4a), w.count > 1000 { return w }
            try? FileManager.default.removeItem(at: u.m4a)          // unreadable: synthesize again
        }
        if let d = try? Data(contentsOf: u.wav), d.count > 1000 { return Narrator.cleanWAV(d) }
        return nil
    }
    private var clipsWritten = 0
    private func storeClip(_ wav: Data, page p: Int, seg i: Int, tag: String, docId: UUID? = nil) {
        let u = clipURLs(p, i, tag: tag, docId: docId)
        if Settings.ttsCacheFormat == "wav" || !AudioCodec.writeAAC(wav: wav, to: u.m4a) {
            try? wav.write(to: u.wav, options: .atomic)
        }
        clipsWritten += 1
        if clipsWritten % 40 == 0 { let keep = docId ?? self.docId; Task.detached(priority: .utility) { StorageManager.enforceAudioLimit(keep: keep) } }
    }

    /// start writing scripts for the pages after `p` (parallel, deduplicated by `script(for:)`)
    private func kickScripts(after p: Int, token: UUID) {
        guard pageCount > 0 else { return }
        let activeDoc = docId
        for k in 1...min(2, Narrator.scriptPagesAhead) where p + k < pageCount {
            let pg = p + k
            if chars(ofPage: pg) != nil { continue }       // already written (in flight ones are joined below)
            Task {
                guard self.docId == activeDoc, self.state != .idle else { return }
                guard let segs = try? await self.script(for: pg), !segs.isEmpty else { return }
                // a new script widens what the audio pipeline can buffer
                if token == self.prefetchToken, self.docId == activeDoc, self.page == p, self.state == .playing {
                    self.prefetch(page: p, from: self.segIndex + 1)
                }
            }
        }
    }

    private func prefetch(page p: Int, from i: Int) {
        prefetchTask?.cancel()
        let token = UUID(); prefetchToken = token
        let activeDoc = docId
        kickScripts(after: p, token: token)
        let first = segments, tag = voiceTag
        let pace = Narrator.pace, speed = Double(max(0.25, rate)), target = Narrator.bufferSeconds
        // plan: upcoming segments over pages that are already scripted, skipping cached audio
        var plan: [(Int, Int, String)] = []
        var ahead = 0.0, count = 0
        var pg = p, k = i, segs = first
        while count < Narrator.maxBufferSegments && (ahead < target || count < Narrator.minBufferSegments) {
            if k < segs.count {
                let t = segs[k].text
                if !hasClip(page: pg, seg: k, tag: tag, docId: activeDoc) { plan.append((pg, k, t)) }
                ahead += Double(t.count) * pace / speed; count += 1; k += 1
                continue
            }
            pg += 1; k = 0
            guard pg < pageCount, let next = cachedScript(pg, docId: activeDoc) else { break }   // not written yet → kickScripts re-triggers
            segs = next
        }
        guard !plan.isEmpty else { refreshBuffered(); return }
        let width = effectiveProvider.isRemote ? 2 : 1
        prefetchTask = Task {
            // sliding window: start the next request as soon as one finishes, in playback order
            await withTaskGroup(of: Void.self) { g in
                var it = plan.makeIterator()
                for _ in 0..<width {
                    guard !Task.isCancelled, token == self.prefetchToken, self.docId == activeDoc, let x = it.next() else { break }
                    g.addTask { _ = try? await self.audio(page: x.0, seg: x.1, text: x.2) }
                }
                while await g.next() != nil {
                    guard !Task.isCancelled, token == self.prefetchToken, self.docId == activeDoc, let x = it.next() else { continue }
                    g.addTask { _ = try? await self.audio(page: x.0, seg: x.1, text: x.2) }
                }
            }
        }
    }

    /// segments buffered (audio ready) ahead of the current one — shown in the UI
    @Published var buffered = 0
    func refreshBuffered() {
        guard docId != nil else { buffered = 0; return }
        var n = 0, pg = page, k = segIndex + 1
        var segs = segments
        let tag = voiceTag
        while n < Narrator.maxBufferSegments {
            if k >= segs.count {
                pg += 1; k = 0
                let u = scriptURL(pg)
                guard pg < pageCount, let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([Segment].self, from: d) else { break }
                segs = s
                continue
            }
            if hasClip(page: pg, seg: k, tag: tag) { n += 1; k += 1 } else { break }
        }
        if buffered != n { buffered = n }
    }

    // MARK: script (Claude, with the page image so figures/tables are explained)

    /// remove every synthesized clip of a page (all engines / voices)
    private func dropAudio(page p: Int, docId: UUID? = nil) {
        let dir = cacheDir(for: docId), prefix = "p\(p)-s"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix(prefix) && (f.hasSuffix(".wav") || f.hasSuffix(".m4a")) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    private func cacheDir(for targetDocId: UUID? = nil) -> URL {
        let u = Paths.docDir(targetDocId ?? docId ?? UUID()).appendingPathComponent("narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func script(for p: Int) async throws -> [Segment] {
        let targetDocId = docId
        let url = scriptURL(p, docId: targetDocId)
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Segment].self, from: d) {
            guard ScriptParser.looksBroken(s.map(\.text)) else { return s }
            // written by an older build whose fallback kept the raw JSON as one segment: repair it in place
            let fixed = ScriptParser.salvage(s.map(\.text).joined(separator: "\n")).map { Segment(text: $0.text, focus: $0.focus) }
            dropAudio(page: p, docId: targetDocId)
            if !fixed.isEmpty {
                if let d = try? JSONEncoder().encode(fixed) { try? d.write(to: url, options: .atomic) }
                pageChars[p] = fixed.reduce(0) { $0 + $1.text.count }; pageCharsMissing.remove(p)
                return fixed
            }
            try? FileManager.default.removeItem(at: url)
        }
        let docPrefix = targetDocId?.uuidString ?? ""
        let taskKey = "\(docPrefix)-\(p)\(scriptSuffix)"
        if let t = scriptTasks[taskKey] { return try await t.value }
        guard let doc = sourceDoc ?? doc, let pg = doc.safePage(p) else { return [] }
        let text = pg.string ?? ""
        let image = Narrator.jpeg(of: pg)
        let prevText = p > 0 ? String((doc.safePage(p - 1)?.string ?? "").suffix(600)) : ""
        let title = self.title, total = doc.pageCount, lang = Settings.targetLang
        let style = Settings.narrationStyle, extra = Settings.narrationExtraPrompt
        let task = Task<[Segment], Error> {
            let sys = NarrationStyle.systemPrompt(style: style, extra: extra, title: title, lang: lang)
            let zh = lang.contains("中文")
            let input = LLMInput(text: zh ? "这是第 \(p + 1)/\(total) 页。\n上一页结尾：\(prevText)\n\n本页文字：\n\(text)"
                                          : "This is page \(p + 1) of \(total).\nEnd of the previous page: \(prevText)\n\nText of this page:\n\(text)", images: [image])
            var out = try await LLMClient.complete(role: "chat", system: sys, input: input, maxTokens: 4000, feature: "narration")
            if let items = ScriptParser.parse(out), !items.isEmpty { return items.map { Segment(text: $0.text, focus: $0.focus) } }
            // unusable reply: ask once more, then salvage whatever is there (never read raw JSON aloud)
            if let again = try? await LLMClient.complete(role: "chat", system: sys + "\n上一次的输出不是合法 JSON，请严格按格式重新输出。", input: input, maxTokens: 4000, feature: "narration") { out = again }
            return ScriptParser.salvage(out).map { Segment(text: $0.text, focus: $0.focus) }
        }
        scriptTasks[taskKey] = task
        defer { scriptTasks[taskKey] = nil }
        let segs = try await task.value
        if let d = try? JSONEncoder().encode(segs) { try? d.write(to: url, options: .atomic) }
        if self.docId == targetDocId {
            pageChars[p] = segs.reduce(0) { $0 + $1.text.count }; pageCharsMissing.remove(p)
        }
        return segs
    }

    // MARK: TTS (gemini-3.8-flash-tts via gateway, OpenAI-compatible /v1/audio/speech)

    func audio(page p: Int, seg i: Int, text: String, urgent: Bool = false) async throws -> Data {
        let targetDocId = docId
        let tag = voiceTag
        let stem = clipStem(p, i, tag: tag)
        let key = "\(targetDocId?.uuidString ?? "")-\(stem)"
        if let w = clipData(page: p, seg: i, tag: tag, docId: targetDocId) { learnPace(key: stem, text: text, wav: w); return w }
        if let t = audioTasks[key] {
            if urgent { promoteSystem(text) }                   // the clip we are waiting on jumps the queue
            return try await t.value
        }
        let remote = effectiveProvider.isRemote
        let cfg = TTSConfig.current(effectiveProvider)
        let task = Task<Data, Error> { @MainActor in
            if !remote { return try await self.systemSynth(text, urgent: urgent) }
            return try await RemoteTTS.synthesize(text, cfg, attempts: 3)
        }
        audioTasks[key] = task
        defer { audioTasks[key] = nil }
        let d: Data
        do { d = try await task.value }
        catch where remote && RemoteTTS.isConfigError(error) {
            // the speech service is not usable (no key / model / permission): switch this run to the macOS voice
            if !fallbackToSystem { fallbackToSystem = true; fallbackReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            return try await audio(page: p, seg: i, text: text, urgent: urgent)
        }
        storeClip(d, page: p, seg: i, tag: tag, docId: targetDocId)
        learnPace(key: stem, text: text, wav: d)
        if self.docId == targetDocId {
            refreshBuffered()
        }
        return d
    }

    /// The gateway wraps the TTS WAV inside another WAV and appends C2PA/SynthID metadata after the PCM.
    /// Played as-is, that metadata is a burst of noise at the end of every clip. Extract the innermost PCM
    /// and rebuild a clean WAV with a short fade-out.
    nonisolated static func cleanWAV(_ d: Data) -> Data {
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 : 0 }
        func tag(_ o: Int) -> String { o + 4 <= d.count ? String(bytes: d[o..<o+4], encoding: .ascii) ?? "" : "" }
        // walk nested RIFF headers, keep the innermost fmt + data
        var pos = 0, fmtAt = -1, dataAt = -1, dataLen = 0
        var guardN = 0
        while pos + 12 <= d.count, tag(pos) == "RIFF", tag(pos + 8) == "WAVE", guardN < 4 {
            guardN += 1
            var c = pos + 12
            var nested = false
            while c + 8 <= d.count {
                let id = tag(c), sz = u32(c + 4)
                if id == "fmt " { fmtAt = c + 8 }
                if id == "data" {
                    dataAt = c + 8; dataLen = min(sz, d.count - dataAt)
                    if tag(dataAt) == "RIFF" { pos = dataAt; nested = true }
                    break
                }
                c += 8 + sz + (sz & 1)
            }
            if !nested { break }
        }
        guard fmtAt > 0, dataAt > 0, u16(fmtAt) == 1 else { return d }
        let ch = u16(fmtAt + 2), rate = u32(fmtAt + 4), bits = u16(fmtAt + 14)
        guard bits == 16, ch > 0 else { return d }
        var pcm = Data(d[dataAt..<(dataAt + dataLen - dataLen % (2 * ch))])
        // 15 ms fade-out to avoid a click at the very end
        let fadeSamples = min(pcm.count / 2 / ch, rate * 15 / 1000)
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            let n = p.count / ch
            for k in 0..<fadeSamples {
                let g = Double(k) / Double(max(1, fadeSamples))
                for c in 0..<ch { let idx = (n - 1 - k) * ch + c; p[idx] = Int16(Double(Int16(littleEndian: p[idx])) * g).littleEndian }
            }
        }
        var out = Data()
        func w32(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func w16(_ v: Int) { var x = UInt16(v).littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append("RIFF".data(using: .ascii)!); w32(36 + pcm.count); out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!); w32(16); w16(1); w16(ch); w32(rate); w32(rate * ch * 2); w16(ch * 2); w16(16)
        out.append("data".data(using: .ascii)!); w32(pcm.count); out.append(pcm)
        return out
    }

    static func jpeg(of page: PDFPage) -> Data {
        PlatformPDF.thumbnailJPEG(page, maxDimension: 1400, quality: 0.72)
    }
}

