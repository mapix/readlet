import Foundation
import AVFoundation
import PDFKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import CoreText

/// Exports the AI narration of the current document as ONE clean MP4 pass (page 0 → last page, every segment
/// in order), built deterministically from the cached scripts + TTS audio — not a screen recording.
/// Missing scripts / audio are filled in the background first (3 requests in flight).
@MainActor
final class NarrationExporter: ObservableObject {
    static let shared = NarrationExporter()

    enum Phase: String { case idle = "", scan = "检查缓存", scripts = "补全讲稿", audio = "补全语音", render = "合成视频", done = "完成", failed = "失败" }

    @Published var phase: Phase = .idle
    @Published var done = 0
    @Published var total = 0
    @Published var detail = ""
    @Published var outputURL: URL?
    /// "一键准备": fill every script + clip for the whole document and stop before rendering video
    @Published var prepareOnly = false
    var running: Bool { task != nil }
    private var task: Task<Void, Never>?

    nonisolated static let W = 1080, H = 1920          // portrait video
    nonisolated static let subtitleH: CGFloat = 420
    nonisolated static let speed: Float = 2.0           // export plays at 2x (pitch preserved)
    static let concurrency = 3

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .done: return prepareOnly ? L("全部讲解和语音已就绪") : L("已导出：") + (outputURL?.lastPathComponent ?? "")
        case .failed: return (prepareOnly ? L("准备失败：") : L("导出失败：")) + detail
        default: return (prepareOnly ? L("准备全部讲解") : L("导出 MP4")) + " · \(L(phase.rawValue)) \(done)/\(total)" + (detail.isEmpty ? "" : " · \(detail)")
        }
    }

    /// run `body` over `items` with `width` in flight, starting the next as soon as one finishes; counts into `done`
    private func window<T>(_ items: [T], width: Int, _ body: @escaping @MainActor (T) async -> Void) async throws {
        var it = items.makeIterator()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<max(1, width) {
                guard let x = it.next() else { break }
                g.addTask { @MainActor in await body(x) }
            }
            while await g.next() != nil {
                done += 1
                if Task.isCancelled { continue }
                if let x = it.next() { g.addTask { @MainActor in await body(x) } }
            }
        }
        try Task.checkCancellation()
    }

    private func log(_ s: String) { print("EXPORT", s); fflush(stdout) }

    func cancel() {
        task?.cancel(); task = nil
        phase = .idle; detail = ""
        log("cancelled")
    }

    /// limitPages: only export the first N pages (testing; env EXPORT_PAGES)
    func start(limitPages: Int? = nil, prepareOnly: Bool = false, forDocId: UUID? = nil, fromPage: Int? = nil) {
        guard task == nil else { return }
        self.prepareOnly = prepareOnly
        let n = Narrator.shared
        if let targetId = forDocId, let ses = Store.shared.session(targetId) {
            n.bindForPrepare(docId: targetId, doc: ses.original, title: ses.doc.title, from: fromPage ?? 0)
        }
        guard let docId = n.docId, let doc = n.narratedDoc, let ses = Store.shared.session(docId) else {
            phase = .failed; detail = L("请先开始 AI 解读"); log("failed: no narration"); return
        }
        let title = n.narratedTitle.isEmpty ? ses.doc.title : n.narratedTitle
        var count = doc.pageCount
        if let l = limitPages, l > 0 { count = min(count, l) }
        guard count > 0 else { phase = .failed; detail = L("文档没有页面"); return }
        outputURL = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(docId: docId, doc: doc, ses: ses, title: title, pageCount: count)
            } catch is CancellationError {
                self.log("cancelled")
            } catch {
                self.phase = .failed; self.detail = error.localizedDescription
                self.log("failed: \(error.localizedDescription)")
            }
            self.task = nil
        }
    }

    static func estimateText(_ plan: Narrator.PreparePlan) -> String {
        let n = Narrator.shared
        let avg = UsageStore.shared.average(feature: "narration") ?? (input: 2600, output: 700)
        let calls = plan.missingScripts
        let inTok = calls * avg.input, outTok = calls * avg.output
        var s = calls == 0 ? L("讲稿已全部生成。") : LF("预计调用模型约 %d 次（约 %@ 输入 / %@ 输出 token）", calls, inTok.compact, outTok.compact)
        let remote = n.effectiveProvider.isRemote
        var cost: Double = 0
        #if os(macOS)
        cost = ChatGPTAuth.shared.connected && ModelConfig.style("chat") == .chatgpt ? 0 : Pricing.cost(model: ModelConfig.chatModel, input: inTok, output: outTok)
        #else
        cost = Pricing.cost(model: ModelConfig.chatModel, input: inTok, output: outTok)
        #endif
        if plan.missingChars > 0 {
            s += remote ? "；" + LF("语音约 %@ 字", plan.missingChars.compact) : "；" + L("语音用系统声音合成，免费")
            if remote { cost += Pricing.ttsCost(chars: plan.missingChars) }
        }
        if Pricing.enabled, cost > 0 { s += "\n" + L("按你设置的单价估算约 ") + Pricing.format(cost) }
        return s
    }

    private func run(docId: UUID, doc: PDFDocument, ses: DocSession, title: String, pageCount: Int) async throws {
        let n = Narrator.shared
        let voice = n.voiceTag
        let dir = Paths.docDir(docId).appendingPathComponent("narration", isDirectory: true)
        let fm = FileManager.default
        func scriptURL(_ p: Int) -> URL { dir.appendingPathComponent(n.scriptFileName(p)) }
        func cached(_ p: Int) -> [Narrator.Segment]? {
            guard let d = try? Data(contentsOf: scriptURL(p)),
                  let s = try? JSONDecoder().decode([Narrator.Segment].self, from: d) else { return nil }
            return ScriptParser.looksBroken(s.map(\.text)) ? nil : s      // broken → re-made by script(for:)
        }

        // 1. scan
        phase = .scan
        // start from the page being narrated, so what you'll hear next is ready first
        let from = min(max(0, n.page), pageCount - 1)
        let order = Array(from..<pageCount) + Array(0..<from)
        let missingScripts = order.filter { cached($0) == nil }
        log("pages \(pageCount) missingScripts \(missingScripts.count)")

        // 2. If prepareOnly, prepare the current page's script and audio first so playback can start immediately
        if prepareOnly, let firstPage = order.first {
            phase = .scripts; total = max(1, missingScripts.count); done = 0; detail = LF("正在准备第 %d 页…", firstPage + 1)
            let firstSegs = (try? await n.script(for: firstPage)) ?? cached(firstPage) ?? []
            try Task.checkCancellation()
            var firstPageAudio: [(Int, Int, String)] = []
            for (i, s) in firstSegs.enumerated() where !n.hasClip(page: firstPage, seg: i, tag: voice) {
                firstPageAudio.append((firstPage, i, s.text))
            }
            if !firstPageAudio.isEmpty {
                phase = .audio; total = firstPageAudio.count; done = 0; detail = LF("第 %d 页语音…", firstPage + 1)
                let firstClip = [firstPageAudio[0]]
                try await window(firstClip, width: 1) { x in _ = try? await n.audio(page: x.0, seg: x.1, text: x.2, urgent: true) }
                let restClips = Array(firstPageAudio.dropFirst())
                if !restClips.isEmpty {
                    try await window(restClips, width: n.effectiveProvider.isRemote ? 2 : 1) { x in _ = try? await n.audio(page: x.0, seg: x.1, text: x.2) }
                }
                try Task.checkCancellation()
            }
        }

        // 3. fill remaining scripts in batches
        let remainingScripts = order.filter { cached($0) == nil }
        phase = .scripts; total = remainingScripts.count; done = 0; detail = remainingScripts.isEmpty ? "" : LF("缺 %d 页", remainingScripts.count)
        try await window(remainingScripts, width: 2) { p in _ = try? await n.script(for: p) }
        try Task.checkCancellation()

        // 4. fill remaining audio in batches
        var scripts: [Int: [Narrator.Segment]] = [:]
        for p in 0..<pageCount { scripts[p] = cached(p) ?? [] }
        var missingAudio: [(Int, Int, String)] = []
        for p in order { for (i, s) in (scripts[p] ?? []).enumerated() where !n.hasClip(page: p, seg: i, tag: voice) { missingAudio.append((p, i, s.text)) } }
        log("missingAudio \(missingAudio.count)")
        phase = .audio; total = missingAudio.count; done = 0; detail = missingAudio.isEmpty ? "" : LF("缺 %d 段", missingAudio.count)
        try await window(missingAudio, width: n.effectiveProvider.isRemote ? 2 : 1) { x in _ = try? await n.audio(page: x.0, seg: x.1, text: x.2) }
        try Task.checkCancellation()

        if prepareOnly {
            phase = .done; total = 0; done = 0; detail = ""
            n.refreshBuffered()
            log("prepared all scripts + audio")
            return
        }

        // 4. collect render plan (main actor: PDFKit lookups + page rasterization)
        phase = .render; total = pageCount; done = 0; detail = L("准备画面")
        var pages: [ExportPage] = []
        var skipped = 0
        for p in 0..<pageCount {
            try Task.checkCancellation()
            let segs = scripts[p] ?? []
            var items: [ExportSegment] = []
            for (i, s) in segs.enumerated() {
                guard let d = n.clipData(page: p, seg: i, tag: voice), let pcm = PCM(wav: d), pcm.samples.count > 0 else { skipped += 1; continue }
                items.append(ExportSegment(text: s.text, focus: Self.focusRect(ses: ses, shownDoc: doc, page: p, quote: s.focus, text: s.text), pcm: pcm))
            }
            guard !items.isEmpty, let pg = doc.safePage(p) else { continue }   // pages without segments: skipped
            guard let img = Self.rasterize(pg) else { continue }
            pages.append(ExportPage(index: p, image: img, box: pg.bounds(for: .cropBox), rotated: pg.rotation % 360 != 0, segments: items))
            await Task.yield()
        }
        if skipped > 0 { log("skipped segments without audio: \(skipped)") }
        guard !pages.isEmpty else { throw TranslateError.bad(L("没有可导出的讲解内容")) }

        let homeDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let base = ProcessInfo.processInfo.environment["EXPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? homeDir.appendingPathComponent("Movies/Readlet", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let out = base.appendingPathComponent("\(safeTitle.isEmpty ? "narration" : safeTitle)-AI解读.mp4")
        try? fm.removeItem(at: out)

        // 5. encode off the main actor
        detail = ""
        let totalPages = pages.count
        total = totalPages
        let job = Task.detached(priority: .userInitiated) {
            try VideoComposer.write(pages: pages, to: out) { pagesDone in
                Task { @MainActor in
                    NarrationExporter.shared.done = pagesDone
                    NarrationExporter.shared.log("render \(pagesDone)/\(totalPages)")
                }
            }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }

        outputURL = out
        phase = .done; detail = ""
        log("done \(out.path)")
        #if os(macOS)
        if ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] == nil { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        #endif
    }

    // MARK: focus region (same idea as ReaderController.highlightNarration, in page coordinates of the shown doc)

    static func focusRect(ses: DocSession, shownDoc: PDFDocument, page i: Int, quote: String?, text: String) -> CGRect? {
        guard let orig = ses.original.safePage(i), let shown = shownDoc.safePage(i) else { return nil }
        guard let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), q.count >= 3 else { return nil }
        var found = ses.original.findString(q, withOptions: [.caseInsensitive]).first { $0.pages.contains(orig) }
        if found == nil, q.count > 10 { found = ses.original.findString(String(q.prefix(10)), withOptions: [.caseInsensitive]).first { $0.pages.contains(orig) } }
        guard let sel = found else { return nil }
        let origBox = orig.bounds(for: .cropBox)
        let isFig = text.range(of: "(图|表|横轴|纵轴|曲线|柱状|折线|示意|figure|table)", options: [.regularExpression, .caseInsensitive]) != nil
        guard var r = paragraph(around: sel.bounds(for: orig), page: orig, isFigure: isFig).sanitized(in: origBox) else { return nil }
        if shown !== orig, let ins = ses.insertions[i], !ins.isEmpty {
            let H0 = origBox.maxY, H1 = shown.bounds(for: .cropBox).maxY
            let top = H1 - DocSession.fromOriginal(H0 - r.maxY, ins)
            let bottomTD = DocSession.fromOriginal(H0 - r.minY, ins)
            var extra: CGFloat = 0
            let cutAfter = ins.filter { $0.count >= 2 && CGFloat($0[0]) >= H0 - r.minY - 2 }.min { $0[0] < $1[0] }
            if let c = cutAfter, CGFloat(c[0]) - (H0 - r.minY) < 24 { extra = CGFloat(c[1]) + (CGFloat(c[0]) - (H0 - r.minY)) }
            let y = H1 - bottomTD - extra
            r = CGRect(x: r.minX, y: y, width: r.width, height: y < top ? top - y : r.height)
        }
        return r.sanitized(in: shown.bounds(for: .cropBox))
    }

    /// expand the hit to its text block (following lines with a small gap); for figure captions, include the area above
    private static func paragraph(around hit: CGRect, page: PDFPage, isFigure: Bool) -> CGRect {
        let full = page.bounds(for: .cropBox)
        let lines = (page.selection(for: full)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }.filter { $0.isSane }
        guard let start = lines.firstIndex(where: { $0.intersects(hit.insetBy(dx: -1, dy: -1)) }) else { return hit.insetBy(dx: -8, dy: -6) }
        var r = lines[start]
        let h = r.height
        guard h > 0 else { return hit.insetBy(dx: -8, dy: -6) }
        var last = r
        // lines are in reading order; keep adding lines just below that overlap horizontally
        for l in lines[(start + 1)...] {
            let gap = last.minY - l.maxY
            let overlapX = min(r.maxX, l.maxX) - max(r.minX, l.minX)
            if abs(l.midY - last.midY) < h * 0.6 { r = r.union(l); continue }        // same line fragment
            guard gap > -h * 0.5, gap < h * 0.9, overlapX > 0 else { break }
            r = r.union(l); last = l
            if r.height > full.height * 0.45 { break }
        }
        if isFigure {   // caption: include the figure above it (up to 45% of the page)
            let above = lines.filter { $0.minY > r.maxY + h }.map { $0.minY }.min() ?? min(full.maxY, r.maxY + full.height * 0.45)
            r = CGRect(x: r.minX, y: r.minY, width: r.width, height: min(above, r.maxY + full.height * 0.45) - r.minY)
        }
        return r.insetBy(dx: -8, dy: -6)
    }

    static func rasterize(_ pg: PDFPage) -> CGImage? {
        let b = pg.bounds(for: .cropBox)
        guard b.isSane else { return nil }
        let availW = CGFloat(W) - 80, availH = CGFloat(H) - subtitleH - 40
        let rotated = pg.rotation % 180 != 0
        let pw = rotated ? b.height : b.width, ph = rotated ? b.width : b.height
        let s = min(availW / pw, availH / ph) * 2      // 2x for crisp text
        guard s.isSane, s > 0 else { return nil }
        return PlatformPDF.thumbnailCGImage(pg, size: CGSize(width: pw * s, height: ph * s), for: .cropBox)
    }
}

// MARK: data

struct PCM: @unchecked Sendable {
    var samples: [Int16]; var rate: Int
    var duration: Double { Double(samples.count) / Double(rate) }
    /// parse a clean (single RIFF, 16-bit PCM) WAV; mixes down to mono
    init?(wav d: Data) {
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 : 0 }
        guard d.count > 44, String(bytes: d[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        var c = 12, ch = 1, r = 24000, bits = 16, dataAt = -1, len = 0
        while c + 8 <= d.count {
            let id = String(bytes: d[c..<c+4], encoding: .ascii) ?? "", sz = u32(c + 4)
            if id == "fmt " { ch = max(1, u16(c + 10)); r = u32(c + 12); bits = u16(c + 22) }
            if id == "data" { dataAt = c + 8; len = min(sz, d.count - dataAt); break }
            c += 8 + sz + (sz & 1)
        }
        guard dataAt > 0, bits == 16, r > 0 else { return nil }
        let frames = len / (2 * ch)
        var out = [Int16](repeating: 0, count: frames)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                var acc = 0
                for k in 0..<ch { let o = dataAt + (f * ch + k) * 2; acc += Int(Int16(bitPattern: UInt16(raw[o]) | UInt16(raw[o + 1]) << 8)) }
                out[f] = Int16(clamping: acc / ch)
            }
        }
        samples = out; rate = r
    }
    func resampled(to target: Int) -> [Int16] {
        guard target != rate, !samples.isEmpty else { return samples }
        let n = Int(Double(samples.count) * Double(target) / Double(rate))
        return (0..<n).map { i in
            let x = Double(i) * Double(rate) / Double(target)
            let a = Int(x), b = min(samples.count - 1, a + 1), t = x - Double(a)
            return Int16(clamping: Int(Double(samples[min(a, samples.count - 1)]) * (1 - t) + Double(samples[b]) * t))
        }
    }
}

struct ExportSegment: @unchecked Sendable { var text: String; var focus: CGRect?; var pcm: PCM }
struct ExportPage: @unchecked Sendable { var index: Int; var image: CGImage; var box: CGRect; var rotated: Bool; var segments: [ExportSegment] }

// MARK: composition + encoding

enum VideoComposer {
    static let W = NarrationExporter.W, H = NarrationExporter.H
    static let rate = 24000
    static let keepAlive = 1.0      // re-emit the still frame every N seconds (seekable, robust players)

    static func write(pages: [ExportPage], to url: URL, progress: @escaping (Int) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw TranslateError.bad(L("无法创建视频写入器")) }
        writer.add(vIn); writer.add(aIn)
        guard writer.startWriting() else { throw writer.error ?? TranslateError.bad("startWriting failed") }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var afmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &afmt)
        guard let audioFmt = afmt else { throw TranslateError.bad(L("音频格式错误")) }

        func wait(_ i: AVAssetWriterInput) throws {
            while !i.isReadyForMoreMediaData {
                if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
                if writer.status == .failed { throw writer.error ?? TranslateError.bad(L("写入失败")) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        func appendFrame(_ img: CGImage, at t: Double) throws {
            try wait(vIn)
            guard let pool = adaptor.pixelBufferPool else { throw TranslateError.bad(L("像素缓冲池不可用")) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { throw TranslateError.bad(L("像素缓冲创建失败")) }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            if !adaptor.append(buf, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) { throw writer.error ?? TranslateError.bad(L("视频帧写入失败")) }
        }
        func appendAudio(_ s: ArraySlice<Int16>, at sampleOffset: Int) throws {
            guard !s.isEmpty else { return }
            try wait(aIn)
            let bytes = s.count * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let bb = block else { throw TranslateError.bad(L("音频缓冲失败")) }
            s.withUnsafeBytes { raw in if let b = raw.baseAddress { CMBlockBufferReplaceDataBytes(with: b, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) } }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: audioFmt, sampleCount: s.count,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(sampleOffset), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sb)
            guard let buf = sb, aIn.append(buf) else { throw writer.error ?? TranslateError.bad(L("音频写入失败")) }
        }

        var cursor = 0          // audio samples written so far (global timeline)
        let chunk = rate / 2    // 0.5 s audio chunks, interleaved with video frames
        for (pi, page) in pages.enumerated() {
            for seg in page.segments {
                if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
                let samples = timeStretch(seg.pcm.resampled(to: rate), rate: rate, speed: NarrationExporter.speed)
                let start = Double(cursor) / Double(rate)
                let dur = Double(samples.count) / Double(rate)
                // plain subtitles: split the segment into short lines, timed by character share
                let lines = subtitleLines(seg.text)
                let total = Double(max(1, lines.reduce(0) { $0 + $1.count }))
                var cues: [(Double, CGImage?)] = []
                var acc = 0.0
                for l in lines { cues.append((start + dur * acc / total, compose(page: page, seg: seg, line: l))); acc += Double(l.count) }
                func frameAt(_ t: Double) -> CGImage? { cues.last(where: { $0.0 <= t + 0.001 })?.1 ?? cues.first?.1 }
                var nextFrame = start
                var ci = 1
                var off = 0
                while off < samples.count {
                    let t = Double(cursor + off) / Double(rate)
                    while nextFrame <= t + 0.5, nextFrame < start + dur {
                        // jump to the next cue boundary if it comes before the keep-alive tick
                        if let f = frameAt(nextFrame) { try appendFrame(f, at: nextFrame) }
                        let nextCue = ci < cues.count ? cues[ci].0 : .infinity
                        if nextCue <= nextFrame + keepAlive { nextFrame = max(nextFrame + 0.04, nextCue); ci += 1 } else { nextFrame += keepAlive }
                    }
                    // the writer interleaves tracks: if audio is blocked, feed the next still frame early
                    while !aIn.isReadyForMoreMediaData, nextFrame < start + dur, vIn.isReadyForMoreMediaData {
                        if let f = frameAt(nextFrame) { try appendFrame(f, at: nextFrame) }
                        let nextCue = ci < cues.count ? cues[ci].0 : .infinity
                        if nextCue <= nextFrame + keepAlive { nextFrame = max(nextFrame + 0.04, nextCue); ci += 1 } else { nextFrame += keepAlive }
                    }
                    let end = min(samples.count, off + chunk)
                    try appendAudio(samples[off..<end], at: cursor + off)
                    off = end
                }
                cursor += samples.count
            }
            progress(pi + 1)
        }
        let endT = CMTime(value: CMTimeValue(cursor), timescale: CMTimeScale(rate))
        // final frame at the very end so the last still lasts until the audio ends
        if let last = pages.last, let ls = last.segments.last, let f = compose(page: last, seg: ls, line: subtitleLines(ls.text).last ?? "") { try appendFrame(f, at: max(0, endT.seconds - 0.05)) }
        vIn.markAsFinished(); aIn.markAsFinished()
        writer.endSession(atSourceTime: endT)
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? TranslateError.bad(L("视频写入未完成")) }
    }

    /// short subtitle lines (≈ one screen line each), split at sentence / clause punctuation
    static func subtitleLines(_ text: String, maxLen: Int = 22) -> [String] {
        var out: [String] = [], cur = "", w = 0.0       // display width: CJK = 1, Latin = 0.5
        let hard: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n"], soft: Set<Character> = ["，", "、", "：", ",", ":"]
        for ch in text {
            cur.append(ch); w += ch.isASCII ? 0.5 : 1
            let inWord = ch.isASCII && (ch.isLetter || ch.isNumber)
            if hard.contains(ch) || (soft.contains(ch) && w >= 8) || (w >= Double(maxLen) && !inWord) || w >= Double(maxLen) + 8 {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; cur = ""; w = 0
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }
        // drop trailing punctuation like normal subtitles; merge tiny fragments
        var merged: [String] = []
        for l in out.map({ String($0.trimmingCharacters(in: CharacterSet(charactersIn: "，。、；：,;:"))) }) where !l.isEmpty {
            if let last = merged.last, last.count + l.count <= 10 { merged[merged.count - 1] = last + " " + l } else { merged.append(l) }
        }
        return merged.isEmpty ? [""] : merged
    }

    /// 2x (or any) speed with pitch preserved, rendered offline through AVAudioUnitTimePitch
    static func timeStretch(_ samples: [Int16], rate: Int, speed: Float) -> [Int16] {
        guard speed != 1, !samples.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return samples }
        inBuf.frameLength = inBuf.frameCapacity
        let ip = inBuf.floatChannelData![0]
        for (i, v) in samples.enumerated() { ip[i] = Float(v) / 32768 }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), tp = AVAudioUnitTimePitch()
        tp.rate = speed
        engine.attach(player); engine.attach(tp)
        engine.connect(player, to: tp, format: fmt); engine.connect(tp, to: engine.mainMixerNode, format: fmt)
        do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096); try engine.start() } catch { return samples }
        player.scheduleBuffer(inBuf, at: nil)
        player.play()
        let target = Int(Double(samples.count) / Double(speed))
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return samples }
        var res: [Int16] = []; res.reserveCapacity(target + 4096)
        while res.count < target {
            let n = AVAudioFrameCount(min(4096, target - res.count))
            guard (try? engine.renderOffline(n, to: out)) == .success else { break }
            let op = out.floatChannelData![0]
            for i in 0..<Int(out.frameLength) { res.append(Int16(max(-1, min(1, op[i])) * 32767)) }
        }
        engine.stop()
        return res.isEmpty ? samples : res
    }

    /// portrait frame: dark background, page card on top (with soft highlight), plain subtitle line below
    static func compose(page: ExportPage, seg: ExportSegment, line: String) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let Wf = CGFloat(W), Hf = CGFloat(H), subH = NarrationExporter.subtitleH
        ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: Wf, height: Hf))
        let area = CGRect(x: 30, y: subH, width: Wf - 60, height: Hf - subH - 90)
        let iw = CGFloat(page.image.width), ih = CGFloat(page.image.height)
        let s = min(area.width / max(1, iw), area.height / max(1, ih))
        let dst = CGRect(x: area.midX - iw * s / 2, y: area.maxY - ih * s, width: iw * s, height: ih * s)
        if dst.isSane {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(dst)
            ctx.interpolationQuality = .high
            ctx.draw(page.image, in: dst)
            if !page.rotated, let r = seg.focus, page.box.isSane {
                let k = dst.width / page.box.width
                let hr = CGRect(x: dst.minX + (r.minX - page.box.minX) * k, y: dst.minY + (r.minY - page.box.minY) * k, width: r.width * k, height: r.height * k)
                    .insetBy(dx: -5, dy: -5).intersection(dst.insetBy(dx: -8, dy: -8))
                if hr.isSane {
                    let path = CGPath(roundedRect: hr, cornerWidth: 8, cornerHeight: 8, transform: nil)
                    ctx.addPath(path); ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.16)); ctx.fillPath()
                    ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 0.89, green: 0.34, blue: 0.12, alpha: 0.85)); ctx.setLineWidth(3); ctx.strokePath()
                }
            }
        }
        // plain subtitle: centred white text with a soft shadow
        let textRect = CGRect(x: 60, y: 90, width: Wf - 120, height: subH - 150)
        var size: CGFloat = 56
        while size >= 34 {
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
            let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowColor = NSColor(white: 0, alpha: 0.9); sh.shadowOffset = .zero
            let str = NSAttributedString(string: line, attributes: [.font: NSFont(name: "PingFang SC Semibold", size: size) ?? NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: sh])
            let fs = CTFramesetterCreateWithAttributedString(str)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: textRect.width, height: .greatestFiniteMagnitude), nil)
            if fit.height <= textRect.height || size <= 34 {
                let h = min(fit.height + 2, textRect.height)
                drawText(str, in: CGRect(x: textRect.minX, y: textRect.midY - h / 2, width: textRect.width, height: h), ctx: ctx)
                break
            }
            size -= 4
        }
        return ctx.makeImage()
    }

    private static func drawText(_ s: NSAttributedString, in r: CGRect, ctx: CGContext) {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: r, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}
