#if os(macOS)
import AppKit
import Foundation
import Combine

/// Checks for new versions of Readlet on launch, periodically in the background, and from the menu / Settings.
/// - Direct builds: checks `/download/latest.json` on the official website.
/// - Mac App Store builds: checks Apple's iTunes Lookup API (`itunes.apple.com/lookup?bundleId=...`) and opens the Mac App Store page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Codable, Equatable {
        let version: String
        let file: String
        let size: String?
        let sha256: String?
        let notes: String?
        var storeURL: String? = nil
    }

    private struct ITunesLookupResponse: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String?
            let releaseNotes: String?
        }
        let resultCount: Int
        let results: [Result]
    }

    private let endpoints = [
        URL(string: "https://readlet.novarock.io/download/latest.json")!,
    ]
    private let downloadBases = [
        URL(string: "https://readlet.novarock.io/download/")!,
    ]

    @Published var availableRelease: Release? = nil
    @Published var checking: Bool = false
    @Published var lastCheckedAt: Date? = nil
    @Published var statusText: String = ""

    private var periodicTimer: Timer?

    var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "autoCheckUpdates") == nil { return true }
            return UserDefaults.standard.bool(forKey: "autoCheckUpdates")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates")
            objectWillChange.send()
            configurePeriodicTimer()
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppInfo.version
    }

    init() {
        configurePeriodicTimer()
    }

    private func configurePeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard autoCheckEnabled, ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] == nil else { return }
        // Check automatically every 6 hours while running
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.check(manual: false)
            }
        }
    }

    func checkOnLaunch() {
        guard autoCheckEnabled, ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] == nil else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        statusText = L("正在检查更新…")
        defer { checking = false }

        do {
            let rel: Release?
            if AppInfo.isAppStore {
                rel = try await fetchAppStoreRelease()
            } else {
                rel = try await fetchDirectRelease()
            }
            lastCheckedAt = Date()
            guard let rel else {
                statusText = LF("已是最新版本 (%@)", Self.currentVersion)
                if manual { showUpToDateAlert() }
                return
            }
            let cur = Self.currentVersion
            let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
            if Self.isNewer(rel.version, than: cur) {
                availableRelease = rel
                statusText = LF("发现新版本 %@", rel.version)
                if manual || skipped != rel.version {
                    prompt(rel, current: cur)
                }
            } else {
                availableRelease = nil
                statusText = LF("已是最新版本 (%@)", cur)
                if manual { showUpToDateAlert() }
            }
        } catch {
            statusText = L("检查更新失败")
            if manual {
                let a = NSAlert()
                a.messageText = L("检查更新失败")
                a.informativeText = L("暂时无法连接更新服务器，请稍后再试。")
                a.addButton(withTitle: L("好"))
                a.runModal()
            }
        }
    }

    private func fetchDirectRelease() async throws -> Release? {
        var lastError: Error?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg)
        for url in endpoints {
            do {
                let (data, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    return try JSONDecoder().decode(Release.self, from: data)
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private func fetchAppStoreRelease() async throws -> Release? {
        let bundleId = Bundle.main.bundleIdentifier ?? "io.novarock.readlet"
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)") else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let (data, _) = try await URLSession(configuration: cfg).data(from: url)
        let lookup = try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
        guard let first = lookup.results.first else { return nil }
        return Release(
            version: first.version,
            file: "",
            size: nil,
            sha256: nil,
            notes: first.releaseNotes,
            storeURL: first.trackViewUrl ?? "macappstore://itunes.apple.com/app/id6823317776?mt=12"
        )
    }

    private func showUpToDateAlert() {
        let a = NSAlert()
        a.messageText = L("已是最新版本")
        a.informativeText = LF("Readlet %@ 是目前的最新版本。", Self.currentVersion)
        a.addButton(withTitle: L("好"))
        a.runModal()
    }

    func openDownload(for r: Release) {
        if let storeURL = r.storeURL, let u = URL(string: storeURL) {
            NSWorkspace.shared.open(u)
            return
        }
        let u = downloadBases[0].appendingPathComponent(r.file)
        NSWorkspace.shared.open(u)
    }

    func prompt(_ r: Release, current: String) {
        let a = NSAlert()
        a.messageText = LF("Readlet %@ 可以更新了", r.version)
        var info = LF("当前版本 %@。", current)
        if let s = r.size, !s.isEmpty { info += "（\(s)）" }
        if let n = r.notes, !n.isEmpty { info += "\n\n" + n }
        a.informativeText = info
        a.addButton(withTitle: L("下载新版本"))
        a.addButton(withTitle: L("稍后"))
        a.addButton(withTitle: L("跳过这个版本"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            openDownload(for: r)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: "skippedVersion")
        default: break
        }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
#endif
