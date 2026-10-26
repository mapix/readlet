import Foundation

/// Disk usage of Readlet's data directory and cache housekeeping.
/// Narration audio is the big one (regenerable): it is kept under a size cap, oldest documents first.
enum StorageManager {
    struct Usage: Equatable {
        var audio: Int64 = 0          // narration clips (.m4a / .wav)
        var video: Int64 = 0          // exported narration videos (.mp4 / .mov)
        var bilingual: Int64 = 0      // rendered bilingual pages
        var pdfs: Int64 = 0           // imported originals
        var other: Int64 = 0          // library, notes, scripts, translations…
        var total: Int64 { audio + video + bilingual + pdfs + other }
    }

    struct DocMediaUsage: Equatable {
        var audioBytes: Int64 = 0
        var audioCount: Int = 0
        var videoBytes: Int64 = 0
        var videoCount: Int = 0
        var scriptBytes: Int64 = 0
        var scriptCount: Int = 0
        var bilingualBytes: Int64 = 0
        var audioAndVideoBytes: Int64 { audioBytes + videoBytes }
        var totalResettableBytes: Int64 { audioBytes + videoBytes + bilingualBytes }
    }

    static var docsDir: URL { Paths.base.appendingPathComponent("docs", isDirectory: true) }

    static var exportedMoviesDir: URL {
        let homeDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let custom = ProcessInfo.processInfo.environment["EXPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return homeDir.appendingPathComponent("Movies/Readlet", isDirectory: true)
    }

    static func usage() -> Usage {
        var u = Usage()
        let fm = FileManager.default
        if let e = fm.enumerator(at: Paths.base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                let n = Int64(v.fileSize ?? 0)
                let path = f.path
                let ext = f.pathExtension.lowercased()
                if path.contains("/narration/"), ext == "m4a" || ext == "wav" { u.audio += n }
                else if ext == "mp4" || ext == "mov" { u.video += n }
                else if path.contains("/bi2-") { u.bilingual += n }
                else if f.lastPathComponent == "original.pdf" || f.lastPathComponent == "original.backup.pdf" { u.pdfs += n }
                else { u.other += n }
            }
        }
        let moviesDir = exportedMoviesDir
        if fm.fileExists(atPath: moviesDir.path),
           let files = try? fm.contentsOfDirectory(at: moviesDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                guard ext == "mp4" || ext == "mov",
                      let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                u.video += Int64(v.fileSize ?? 0)
            }
        }
        return u
    }

    /// Computes audio clips, exported video files, scripts, and bilingual cache size for a single document.
    static func docMediaUsage(_ docId: UUID, title: String? = nil) -> DocMediaUsage {
        var out = DocMediaUsage()
        let fm = FileManager.default
        let docDir = Paths.docDir(docId)
        let narrDir = docDir.appendingPathComponent("narration", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: narrDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for f in files {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                let sz = Int64(v.fileSize ?? 0)
                let ext = f.pathExtension.lowercased()
                let name = f.lastPathComponent
                if ext == "m4a" || ext == "wav" {
                    out.audioBytes += sz
                    out.audioCount += 1
                } else if ext == "mp4" || ext == "mov" {
                    out.videoBytes += sz
                    out.videoCount += 1
                } else if name.hasPrefix("p") && ext == "json" && name != "progress.json" {
                    out.scriptBytes += sz
                    out.scriptCount += 1
                }
            }
        }
        if let subs = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for sub in subs {
                let name = sub.lastPathComponent
                let ext = sub.pathExtension.lowercased()
                if ext == "mp4" || ext == "mov" {
                    let sz = Int64((try? sub.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    out.videoBytes += sz
                    out.videoCount += 1
                } else if name.hasPrefix("bi2-"),
                          let e = fm.enumerator(at: sub, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let bf as URL in e {
                        if let v = try? bf.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                            out.bilingualBytes += Int64(v.fileSize ?? 0)
                        }
                    }
                }
            }
        }
        for vURL in matchingExportedVideoURLs(docId: docId, title: title) {
            if let v = try? vURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                out.videoBytes += Int64(v.fileSize ?? 0)
                out.videoCount += 1
            }
        }
        return out
    }

    private static func matchingExportedVideoURLs(docId: UUID, title: String?) -> [URL] {
        let fm = FileManager.default
        let moviesDir = exportedMoviesDir
        guard fm.fileExists(atPath: moviesDir.path),
              let files = try? fm.contentsOfDirectory(at: moviesDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return []
        }
        let safeTitle = (title ?? "")
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return files.filter { f in
            let ext = f.pathExtension.lowercased()
            guard ext == "mp4" || ext == "mov" else { return false }
            let base = f.deletingPathExtension().lastPathComponent
            if base.contains(docId.uuidString) { return true }
            if !safeTitle.isEmpty && (base == "\(safeTitle)-AI解读" || base.hasPrefix(safeTitle + "-")) { return true }
            return false
        }
    }

    /// Resets/clears audio & video space for a single document (and optionally narration scripts / bilingual cache).
    /// Returns the number of bytes freed.
    @discardableResult
    static func resetDocMedia(
        _ docId: UUID,
        title: String? = nil,
        includeScripts: Bool = false,
        includeBilingual: Bool = false
    ) -> Int64 {
        let fm = FileManager.default
        let before = docMediaUsage(docId, title: title)
        var freed: Int64 = before.audioAndVideoBytes
        if includeScripts { freed += before.scriptBytes }
        if includeBilingual { freed += before.bilingualBytes }

        let docDir = Paths.docDir(docId)
        let narrDir = docDir.appendingPathComponent("narration", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: narrDir, includingPropertiesForKeys: nil) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                let name = f.lastPathComponent
                if ext == "m4a" || ext == "wav" || ext == "mp4" || ext == "mov" {
                    try? fm.removeItem(at: f)
                } else if includeScripts && name.hasPrefix("p") && ext == "json" && name != "progress.json" {
                    try? fm.removeItem(at: f)
                }
            }
        }
        if let subs = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
            for sub in subs {
                let ext = sub.pathExtension.lowercased()
                if ext == "mp4" || ext == "mov" {
                    try? fm.removeItem(at: sub)
                } else if includeBilingual && sub.lastPathComponent.hasPrefix("bi2-") {
                    try? fm.removeItem(at: sub)
                }
            }
        }
        for vURL in matchingExportedVideoURLs(docId: docId, title: title) {
            try? fm.removeItem(at: vURL)
        }
        Task { @MainActor in
            if Narrator.shared.docId == docId {
                if Narrator.shared.state != .idle {
                    Narrator.shared.stop()
                }
                Narrator.shared.refreshBuffered()
            }
        }
        return freed
    }

    /// clips per document: (docId, bytes, newest modification)
    static func audioByDoc() -> [(id: UUID, bytes: Int64, newest: Date, files: [URL])] {
        let fm = FileManager.default
        var out: [(UUID, Int64, Date, [URL])] = []
        for d in (try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: d.lastPathComponent) else { continue }
            let nd = d.appendingPathComponent("narration", isDirectory: true)
            var bytes: Int64 = 0, newest = Date.distantPast, files: [URL] = []
            for f in (try? fm.contentsOfDirectory(at: nd, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            where f.pathExtension == "m4a" || f.pathExtension == "wav" {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, m > newest { newest = m }
                files.append(f)
            }
            if !files.isEmpty { out.append((id, bytes, newest, files)) }
        }
        return out.map { (id: $0.0, bytes: $0.1, newest: $0.2, files: $0.3) }
    }

    /// delete clips of the least recently narrated documents until the cache fits the limit
    static func enforceAudioLimit(keep: UUID?) {
        let limit = Int64(max(0.2, Settings.ttsCacheLimitGB) * 1_073_741_824)
        var docs = audioByDoc()
        var total = docs.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return }
        docs.sort { $0.newest < $1.newest }
        for d in docs where d.id != keep {
            for f in d.files { try? FileManager.default.removeItem(at: f) }
            total -= d.bytes
            if total <= limit { break }
        }
    }

    static func clearAudio(doc: UUID? = nil) {
        for d in audioByDoc() where doc == nil || d.id == doc {
            for f in d.files { try? FileManager.default.removeItem(at: f) }
        }
        if doc == nil {
            let fm = FileManager.default
            let moviesDir = exportedMoviesDir
            if let files = try? fm.contentsOfDirectory(at: moviesDir, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension.lowercased() == "mp4" || f.pathExtension.lowercased() == "mov" {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    /// rendered bilingual pages; skipped for documents that are open (their pages are in use)
    static func clearBilingual(doc: UUID? = nil, open: Set<UUID>) {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: d.lastPathComponent), doc == nil || id == doc, !open.contains(id) else { continue }
            for sub in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where sub.lastPathComponent.hasPrefix("bi2-") {
                try? fm.removeItem(at: sub)
            }
        }
    }

    /// convert WAV clips written by older builds to AAC; returns bytes saved
    static func compressLegacyClips(progress: ((Int, Int) -> Void)? = nil) -> Int64 {
        let wavs = audioByDoc().flatMap { $0.files }.filter { $0.pathExtension == "wav" }
        var saved: Int64 = 0
        for (k, w) in wavs.enumerated() {
            progress?(k, wavs.count)
            guard let d = try? Data(contentsOf: w), d.count > 1000 else { continue }
            let m4a = w.deletingLastPathComponent().appendingPathComponent(
                w.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-v2", with: "-v3") + ".m4a")
            if AudioCodec.writeAAC(wav: Narrator.cleanWAV(d), to: m4a) {
                let after = (try? m4a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                saved += Int64(d.count - after)
                try? FileManager.default.removeItem(at: w)
            }
        }
        progress?(wavs.count, wavs.count)
        return saved
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
