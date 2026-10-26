import Foundation
import Combine
import PDFKit

/// Automatic two-way iCloud synchronization between macOS and iOS/iPadOS.
/// Syncs:
/// - `Library` (`docs`, `notebooks`, `cards`, `links`, workflow tags `TODO`/`DOING`/`DONE`, reading progress %)
/// - Document PDFs (`docs/<UUID>/original.pdf`) and cover thumbnails (`thumb.png`)
/// - Card image excerpts (`images/<UUID>.png`)
/// - Narration scripts & progress (`docs/<UUID>/narration/p*.json`, `progress.json`)
/// - Flashcards (`flashcards.json`) and Copilot chat history (`copilot.json`)
/// - AI Gateway & TTS configuration (`cloud-settings.json` + `NSUbiquitousKeyValueStore`)
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    nonisolated static let containerIdentifier = "iCloud.io.novarock.readlet"

    enum State: Equatable {
        case idle
        case syncing
        case synced(Date)
        case unavailable(String)
        case error(String)

        var isSyncing: Bool {
            if case .syncing = self { return true }
            return false
        }
    }

    struct TombstoneSet: Codable {
        var deletedIds: [UUID: Date] = [:]
    }

    struct CloudSettingsPayload: Codable, Equatable {
        var updatedAt: Date
        var baseURL: String
        var model: String
        var translateModel: String
        var translateProtocol: String
        var assistantModel: String
        var assistantProtocol: String
        var targetLang: String
        var ttsProvider: String
        var ttsVoice: String
        var ttsSpeed: Float
        var narrationStyle: String
        var narrationExtraPrompt: String
        var apiKey: String?
        var systemVoice: String? = nil
        var ttsRegion: String? = nil
        var ttsAppId: String? = nil
        var providerVoices: [String: String]? = nil
        var providerModels: [String: String]? = nil
        var providerBaseURLs: [String: String]? = nil
    }

    @Published var isEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "icloud.sync.enabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "icloud.sync.enabled")
    }() {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "icloud.sync.enabled")
            if isEnabled { syncNow() }
        }
    }

    @Published var state: State = .idle
    @Published var lastSyncedAt: Date? = UserDefaults.standard.object(forKey: "icloud.sync.lastDate") as? Date
    @Published var syncedDocsCount: Int = 0
    @Published var syncedCardsCount: Int = 0
    @Published var cloudLocationDescription: String = ""
    @Published var downloadingDocs: Set<UUID> = []

    private var syncTask: Task<Void, Never>?
    private var debounceWork: DispatchWorkItem?
    private var timer: Timer?
    private var isApplyingRemoteChanges = false
    private var isRunningSync = false
    private var started = false

    private init() {}

    /// Ensures a document's `original.pdf` is downloaded and valid on local disk, triggering iCloud download if needed.
    func ensurePDFDownloaded(_ docId: UUID) async -> Bool {
        let localPDF = Paths.pdf(docId)
        if Paths.hasLocalPDF(docId), PDFDocument(url: localPDF) != nil {
            Store.shared.sessions[docId] = nil
            return Store.shared.session(docId) != nil
        }
        downloadingDocs.insert(docId)
        defer { downloadingDocs.remove(docId) }

        syncNow(silent: false)

        let cloudDirs = Self.resolveCloudDirectories()
        let fm = FileManager.default
        for attempt in 0..<24 {
            for dir in cloudDirs {
                let cloudDocDir = dir.appendingPathComponent("docs/\(docId.uuidString)", isDirectory: true)
                let cloudPDF = cloudDocDir.appendingPathComponent("original.pdf")
                let cloudPlaceholder = cloudDocDir.appendingPathComponent(".original.pdf.icloud")
                if fm.fileExists(atPath: cloudPlaceholder.path) {
                    try? fm.startDownloadingUbiquitousItem(at: cloudPlaceholder)
                }
                if fm.fileExists(atPath: cloudPDF.path) {
                    try? fm.startDownloadingUbiquitousItem(at: cloudPDF)
                }
                Self.syncFileBidirectional(local: localPDF, cloud: cloudPDF)
                Self.syncFileBidirectional(
                    local: Paths.docDir(docId).appendingPathComponent("thumb.png"),
                    cloud: cloudDocDir.appendingPathComponent("thumb.png")
                )
                let lNarr = Paths.docDir(docId).appendingPathComponent("narration", isDirectory: true)
                let cNarr = cloudDocDir.appendingPathComponent("narration", isDirectory: true)
                Self.syncDirectoryFilesBidirectional(localDir: lNarr, cloudDir: cNarr, extensions: ["json"])
            }
            if Paths.hasLocalPDF(docId), PDFDocument(url: localPDF) != nil {
                Store.shared.sessions[docId] = nil
                return Store.shared.session(docId) != nil
            }
            if attempt < 23 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return Paths.hasLocalPDF(docId) && PDFDocument(url: localPDF) != nil
    }

    nonisolated private static func writeDataIfChanged(_ data: Data, to url: URL) {
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Cloud Container Resolution

    /// Returns all active iCloud sync directories (Ubiquity container and/or macOS iCloud Drive `Mobile Documents`).
    nonisolated static func resolveCloudDirectories() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []

        func addDir(_ url: URL) {
            let std = url.standardizedFileURL
            if !dirs.contains(where: { $0.standardizedFileURL.path == std.path }) {
                try? fm.createDirectory(at: std, withIntermediateDirectories: true)
                if fm.fileExists(atPath: std.path), (try? fm.contentsOfDirectory(atPath: std.path)) != nil {
                    dirs.append(std)
                }
            }
        }

        // 1. Explicit override (used by tests or custom user environment)
        if let custom = ProcessInfo.processInfo.environment["READLET_ICLOUD_DIR"], !custom.isEmpty {
            addDir(URL(fileURLWithPath: custom, isDirectory: true))
            return dirs
        }

        // 2. User-selected iCloud Drive folder bookmark (e.g. on iOS if ubiquity entitlement isn't active)
        if let bm = UserDefaults.standard.data(forKey: "icloud.customFolderBookmark") {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) {
                _ = u.startAccessingSecurityScopedResource()
                addDir(u)
            }
        }

        // 3. Native Apple Ubiquity Container (`iCloud.io.novarock.readlet`)
        // Note: Only call url(forUbiquityContainerIdentifier:) when running inside an app bundle with a bundleIdentifier
        if Bundle.main.bundleIdentifier != nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            if let u = fm.url(forUbiquityContainerIdentifier: containerIdentifier)?.appendingPathComponent("Documents", isDirectory: true) {
                addDir(u)
            } else if let u = fm.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true) {
                addDir(u)
            }
        }

        // 4. macOS & iOS Simulator direct iCloud Drive (`~/Library/Mobile Documents`)
        var candidateHomes: [String] = [NSHomeDirectory()]
        #if os(macOS)
        let comps = NSHomeDirectory().split(separator: "/")
        if comps.count >= 2, comps[0] == "Users" {
            let realHome = "/Users/\(comps[1])"
            if !candidateHomes.contains(realHome) {
                candidateHomes.insert(realHome, at: 0)
            }
        }
        #endif
        #if targetEnvironment(simulator)
        var hostUserHome: String? = nil
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !hostHome.isEmpty {
            hostUserHome = hostHome
            candidateHomes.insert(hostHome, at: 0)
        } else {
            // Derive host user home from simulator path `/Users/<user>/Library/Developer/CoreSimulator/...`
            let comps = NSHomeDirectory().split(separator: "/")
            if comps.count >= 2, comps[0] == "Users" {
                let derived = "/Users/\(comps[1])"
                hostUserHome = derived
                candidateHomes.insert(derived, at: 0)
            }
        }
        #endif

        for home in candidateHomes {
            let mobileDocs = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            if fm.fileExists(atPath: mobileDocs.path) {
                // App-specific iCloud container folder in Mobile Documents
                let appContainer = mobileDocs
                    .appendingPathComponent("iCloud~io~novarock~readlet/Documents", isDirectory: true)
                addDir(appContainer)

                // Visible `Readlet` folder inside iCloud Drive (`com~apple~CloudDocs/Readlet`)
                // so files are also accessible via iCloud Drive / Files.app on iPhone & iPad!
                let cloudDocsRoot = mobileDocs.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
                if fm.fileExists(atPath: cloudDocsRoot.path) {
                    addDir(cloudDocsRoot.appendingPathComponent("Readlet", isDirectory: true))
                }
            }
            #if os(macOS)
            // Bridge non-sandboxed Application Support and MAS Container Application Support on the same Mac if accessible
            let nonSandboxedSupport = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Readlet", isDirectory: true)
            if nonSandboxedSupport.standardizedFileURL.path != Paths.base.standardizedFileURL.path,
               fm.fileExists(atPath: nonSandboxedSupport.path) {
                addDir(nonSandboxedSupport)
            }
            #endif
        }

        #if targetEnvironment(simulator)
        // On macOS Sequoia+, `~/Library/Mobile Documents` is TCC-protected for Simulator child processes,
        // while the host Mac's `~/Library/Application Support/Readlet` (which Mac Readlet syncs with iCloud Drive)
        // is accessible without TCC prompts. Bridging it enables automatic Mac <-> iPhone Simulator iCloud sync.
        if let hostUserHome {
            let hostAppSupport = URL(fileURLWithPath: hostUserHome, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Readlet", isDirectory: true)
            addDir(hostAppSupport)
        }
        #endif

        return dirs
    }

    // MARK: - Lifecycle & Automatic Triggers

    func start() {
        guard !started else { return }
        started = true

        let dirs = Self.resolveCloudDirectories()
        if let first = dirs.first {
            cloudLocationDescription = first.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        } else {
            state = .unavailable("iCloud Drive 未启用")
        }

        // Observe NSUbiquitousKeyValueStore changes when running as a bundled app
        if Bundle.main.bundleIdentifier != nil {
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(delay: 0.8, silent: true) }
            }
            NSUbiquitousKeyValueStore.default.synchronize()
        }

        // Periodic background sync every 15 seconds so edits on Mac / iPhone propagate automatically
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled, !self.isRunningSync else { return }
                self.syncNow(silent: true)
            }
        }

        // Initial sync shortly after launch
        scheduleSync(delay: 0.5, silent: lastSyncedAt != nil)
    }

    func setCustomCloudFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkCreationOptions = []
        #endif
        if let bm = try? url.bookmarkData(options: opts, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bm, forKey: "icloud.customFolderBookmark")
        }
        cloudLocationDescription = url.path
        syncNow(silent: false)
    }

    /// Schedules a debounced sync after local data changes (`Store.save()` / `Store.saveNow()`).
    func notifyLocalChange() {
        guard isEnabled, !isApplyingRemoteChanges else { return }
        scheduleSync(delay: 1.5, silent: true)
    }

    func scheduleSync(delay: TimeInterval = 1.0, silent: Bool = true) {
        guard isEnabled else { return }
        debounceWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.syncNow(silent: silent) }
        }
        debounceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: - Tombstone Management

    private static var localTombstoneFile: URL {
        Paths.base.appendingPathComponent("deleted-items.json")
    }

    nonisolated static func loadTombstones(from file: URL) -> TombstoneSet {
        guard let d = try? Data(contentsOf: file),
              let t = try? JSONDecoder().decode(TombstoneSet.self, from: d) else {
            return TombstoneSet()
        }
        return t
    }

    nonisolated static func saveTombstones(_ set: TombstoneSet, to file: URL) {
        if let d = try? JSONEncoder().encode(set) {
            writeDataIfChanged(d, to: file)
        }
    }

    func recordDeletion(_ id: UUID) {
        recordDeletions([id])
    }

    func recordDeletions<S: Sequence>(_ ids: S) where S.Element == UUID {
        var t = Self.loadTombstones(from: Self.localTombstoneFile)
        let now = Date()
        for id in ids {
            t.deletedIds[id] = now
        }
        Self.saveTombstones(t, to: Self.localTombstoneFile)
        notifyLocalChange()
    }

    // MARK: - Two-Way Conflict-Free Library Merge

    /// Merges `local` and `remote` libraries deterministically without losing documents, progress, tags, cards, or mind-map nodes,
    /// while detecting cross-device reading progress conflicts and merging per-device snapshots + daily reading logs.
    nonisolated static func mergeLibraries(
        local: Library,
        remote: Library,
        deleted: Set<UUID>
    ) -> (merged: Library, localChanged: Bool, remoteChanged: Bool) {
        var out = Library()

        // 1. Merge Docs
        var docsById: [UUID: Doc] = [:]
        var docOrder: [UUID] = []
        for d in local.docs where !deleted.contains(d.id) {
            docsById[d.id] = d
            docOrder.append(d.id)
        }
        for r in remote.docs where !deleted.contains(r.id) {
            if let l = docsById[r.id] {
                var mergedDoc = l
                let lTime = l.updatedAt ?? l.added
                let rTime = r.updatedAt ?? r.added
                if rTime > lTime {
                    mergedDoc.title = r.title
                    mergedDoc.source = r.source ?? l.source
                    mergedDoc.updatedAt = r.updatedAt
                } else {
                    mergedDoc.source = l.source ?? r.source
                }
                // Status tag comes from whichever side was modified more recently; custom tags are unioned across devices
                let winningStatus = (rTime > lTime ? r.statusTag : l.statusTag) ?? l.statusTag ?? r.statusTag
                var mergedTags: [String] = []
                if let st = winningStatus { mergedTags.append(st.rawValue) }
                for ct in (l.customTags + r.customTags) where !mergedTags.contains(ct) {
                    mergedTags.append(ct)
                }
                mergedDoc.tags = mergedTags
                mergedDoc.pageCount = l.pageCount ?? r.pageCount

                // Merge dailyReadingLog (keep highest page reached on each date)
                var combinedDaily = l.dailyReadingLog
                for (day, pg) in r.dailyReadingLog {
                    combinedDaily[day] = max(combinedDaily[day] ?? 0, pg)
                }
                if combinedDaily.count > 45 {
                    let keep = Set(combinedDaily.keys.sorted(by: >).prefix(45))
                    combinedDaily = combinedDaily.filter { keep.contains($0.key) }
                }
                mergedDoc.dailyReadingLog = combinedDaily

                // Merge deviceProgressHistory across both sides (plus current local/remote endpoints)
                var snapshotsByDevice: [String: DeviceProgressSnapshot] = [:]
                for snap in (l.deviceProgressHistory + r.deviceProgressHistory) {
                    let key = snap.deviceId.isEmpty ? snap.deviceName : snap.deviceId
                    if let existing = snapshotsByDevice[key] {
                        if snap.updatedAt > existing.updatedAt || (snap.updatedAt == existing.updatedAt && snap.readPage > existing.readPage) {
                            snapshotsByDevice[key] = snap
                        }
                    } else {
                        snapshotsByDevice[key] = snap
                    }
                }
                if let lp = l.readPage, let lDev = l.lastReadDevice, !lDev.isEmpty {
                    let key = (l.lastReadDeviceId?.isEmpty == false) ? l.lastReadDeviceId! : lDev
                    let snap = DeviceProgressSnapshot(
                        deviceId: l.lastReadDeviceId ?? lDev,
                        deviceName: lDev,
                        readPage: lp,
                        narrationPage: l.narrationPage,
                        narrationSeg: l.narrationSeg,
                        updatedAt: l.readUpdatedAt ?? lTime
                    )
                    if let existing = snapshotsByDevice[key] {
                        if snap.updatedAt >= existing.updatedAt { snapshotsByDevice[key] = snap }
                    } else {
                        snapshotsByDevice[key] = snap
                    }
                }
                if let rp = r.readPage, let rDev = r.lastReadDevice, !rDev.isEmpty {
                    let key = (r.lastReadDeviceId?.isEmpty == false) ? r.lastReadDeviceId! : rDev
                    let snap = DeviceProgressSnapshot(
                        deviceId: r.lastReadDeviceId ?? rDev,
                        deviceName: rDev,
                        readPage: rp,
                        narrationPage: r.narrationPage,
                        narrationSeg: r.narrationSeg,
                        updatedAt: r.readUpdatedAt ?? rTime
                    )
                    if let existing = snapshotsByDevice[key] {
                        if snap.updatedAt >= existing.updatedAt { snapshotsByDevice[key] = snap }
                    } else {
                        snapshotsByDevice[key] = snap
                    }
                }
                mergedDoc.deviceProgressHistory = Array(
                    snapshotsByDevice.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(6)
                )

                // Reading progress merge & conflict detection
                let lReadTime = l.readUpdatedAt ?? lTime
                let rReadTime = r.readUpdatedAt ?? rTime
                if let lp = l.readPage, let rp = r.readPage {
                    if lp == rp {
                        mergedDoc.readPage = lp
                        if rReadTime > lReadTime {
                            mergedDoc.readUpdatedAt = r.readUpdatedAt ?? l.readUpdatedAt
                            mergedDoc.lastReadDevice = r.lastReadDevice ?? l.lastReadDevice
                            mergedDoc.lastReadDeviceId = r.lastReadDeviceId ?? l.lastReadDeviceId
                        } else {
                            mergedDoc.readUpdatedAt = l.readUpdatedAt ?? r.readUpdatedAt
                            mergedDoc.lastReadDevice = l.lastReadDevice ?? r.lastReadDevice
                            mergedDoc.lastReadDeviceId = l.lastReadDeviceId ?? r.lastReadDeviceId
                        }
                        mergedDoc.pendingConflict = nil
                    } else {
                        let lDevId = l.lastReadDeviceId ?? ""
                        let rDevId = r.lastReadDeviceId ?? ""
                        let lDevName = l.lastReadDevice ?? "Mac"
                        let rDevName = r.lastReadDevice ?? "iPhone"
                        let differentDevices: Bool = {
                            if !lDevId.isEmpty && !rDevId.isEmpty { return lDevId != rDevId }
                            if l.lastReadDevice != nil && r.lastReadDevice != nil { return lDevName != rDevName }
                            return true
                        }()
                        let pageDelta = abs(lp - rp)
                        let newerWentBackwards = (rReadTime > lReadTime && rp < lp) || (lReadTime > rReadTime && lp < rp)
                        let bothHaveExplicitReadDates = l.readUpdatedAt != nil && r.readUpdatedAt != nil
                        let concurrentDivergence = bothHaveExplicitReadDates
                            && abs(rReadTime.timeIntervalSince(lReadTime)) < 6 * 3600
                            && pageDelta >= 3

                        // Detect conflict if two devices diverge and either the newer timestamp is on an earlier page
                        // or both devices explicitly updated reading positions recently to different pages
                        if differentDevices && pageDelta >= 2 && (newerWentBackwards || concurrentDivergence) {
                            mergedDoc.pendingConflict = ProgressConflict(
                                localDeviceId: lDevId.isEmpty ? "local" : lDevId,
                                localDeviceName: lDevName,
                                localPage: lp,
                                localNarrationPage: l.narrationPage,
                                localNarrationSeg: l.narrationSeg,
                                localUpdatedAt: lReadTime,
                                remoteDeviceId: rDevId.isEmpty ? "remote" : rDevId,
                                remoteDeviceName: rDevName,
                                remotePage: rp,
                                remoteNarrationPage: r.narrationPage,
                                remoteNarrationSeg: r.narrationSeg,
                                remoteUpdatedAt: rReadTime,
                                detectedAt: max(lReadTime, rReadTime)
                            )
                        } else {
                            mergedDoc.pendingConflict = l.pendingConflict ?? r.pendingConflict
                        }

                        // Tentative winning page:
                        // If one side is at page 0 (just opened) and the other is > 0, never let page 0 clobber non-zero progress;
                        // otherwise if explicit readUpdatedAt timestamps exist, prefer the newer one; otherwise prefer max(lp, rp).
                        if lp == 0 && rp > 0 {
                            mergedDoc.readPage = rp
                            mergedDoc.readUpdatedAt = r.readUpdatedAt ?? l.readUpdatedAt
                            mergedDoc.lastReadDevice = r.lastReadDevice ?? l.lastReadDevice
                            mergedDoc.lastReadDeviceId = r.lastReadDeviceId ?? l.lastReadDeviceId
                        } else if rp == 0 && lp > 0 {
                            mergedDoc.readPage = lp
                            mergedDoc.readUpdatedAt = l.readUpdatedAt ?? r.readUpdatedAt
                            mergedDoc.lastReadDevice = l.lastReadDevice ?? r.lastReadDevice
                            mergedDoc.lastReadDeviceId = l.lastReadDeviceId ?? r.lastReadDeviceId
                        } else if bothHaveExplicitReadDates && !newerWentBackwards {
                            if rReadTime >= lReadTime {
                                mergedDoc.readPage = rp
                                mergedDoc.readUpdatedAt = r.readUpdatedAt
                                mergedDoc.lastReadDevice = r.lastReadDevice ?? l.lastReadDevice
                                mergedDoc.lastReadDeviceId = r.lastReadDeviceId ?? l.lastReadDeviceId
                            } else {
                                mergedDoc.readPage = lp
                                mergedDoc.readUpdatedAt = l.readUpdatedAt
                                mergedDoc.lastReadDevice = l.lastReadDevice ?? r.lastReadDevice
                                mergedDoc.lastReadDeviceId = l.lastReadDeviceId ?? r.lastReadDeviceId
                            }
                        } else {
                            if rp >= lp {
                                mergedDoc.readPage = rp
                                mergedDoc.readUpdatedAt = r.readUpdatedAt ?? l.readUpdatedAt
                                mergedDoc.lastReadDevice = r.lastReadDevice ?? l.lastReadDevice
                                mergedDoc.lastReadDeviceId = r.lastReadDeviceId ?? l.lastReadDeviceId
                            } else {
                                mergedDoc.readPage = lp
                                mergedDoc.readUpdatedAt = l.readUpdatedAt ?? r.readUpdatedAt
                                mergedDoc.lastReadDevice = l.lastReadDevice ?? r.lastReadDevice
                                mergedDoc.lastReadDeviceId = l.lastReadDeviceId ?? r.lastReadDeviceId
                            }
                        }
                    }
                } else if let rp = r.readPage {
                    mergedDoc.readPage = rp
                    mergedDoc.readUpdatedAt = r.readUpdatedAt
                    mergedDoc.lastReadDevice = r.lastReadDevice
                    mergedDoc.lastReadDeviceId = r.lastReadDeviceId
                } else if let lp = l.readPage {
                    mergedDoc.readPage = lp
                    mergedDoc.readUpdatedAt = l.readUpdatedAt
                    mergedDoc.lastReadDevice = l.lastReadDevice
                    mergedDoc.lastReadDeviceId = l.lastReadDeviceId
                }

                // Merge AI Narration progress (ignoring trivial page 0 seg 0 when non-zero progress exists)
                let lHasNarr = (l.narrationPage ?? 0) > 0 || (l.narrationSeg ?? 0) > 0
                let rHasNarr = (r.narrationPage ?? 0) > 0 || (r.narrationSeg ?? 0) > 0
                if lHasNarr && rHasNarr {
                    let lnt = l.narrationUpdatedAt ?? lTime
                    let rnt = r.narrationUpdatedAt ?? rTime
                    if rnt > lnt {
                        mergedDoc.narrationPage = r.narrationPage
                        mergedDoc.narrationSeg = r.narrationSeg
                        mergedDoc.narrationUpdatedAt = r.narrationUpdatedAt
                        mergedDoc.lastNarrationDevice = r.lastNarrationDevice ?? l.lastNarrationDevice
                    } else {
                        mergedDoc.narrationPage = l.narrationPage
                        mergedDoc.narrationSeg = l.narrationSeg
                        mergedDoc.narrationUpdatedAt = l.narrationUpdatedAt
                        mergedDoc.lastNarrationDevice = l.lastNarrationDevice ?? r.lastNarrationDevice
                    }
                } else if rHasNarr {
                    mergedDoc.narrationPage = r.narrationPage
                    mergedDoc.narrationSeg = r.narrationSeg
                    mergedDoc.narrationUpdatedAt = r.narrationUpdatedAt
                    mergedDoc.lastNarrationDevice = r.lastNarrationDevice
                } else if lHasNarr {
                    mergedDoc.narrationPage = l.narrationPage
                    mergedDoc.narrationSeg = l.narrationSeg
                    mergedDoc.narrationUpdatedAt = l.narrationUpdatedAt
                    mergedDoc.lastNarrationDevice = l.lastNarrationDevice
                }
                docsById[r.id] = mergedDoc
            } else {
                docsById[r.id] = r
                docOrder.append(r.id)
            }
        }
        out.docs = docOrder.compactMap { docsById[$0] }
        let validDocIds = Set(out.docs.map(\.id))

        // 2. Merge Cards
        var cardsById: [UUID: Card] = [:]
        var cardOrder: [UUID] = []
        for c in local.cards where !deleted.contains(c.id) && validDocIds.contains(c.docId) {
            cardsById[c.id] = c
            cardOrder.append(c.id)
        }
        for r in remote.cards where !deleted.contains(r.id) && validDocIds.contains(r.docId) {
            if let l = cardsById[r.id] {
                let lTime = l.updatedAt ?? l.created
                let rTime = r.updatedAt ?? r.created
                var mc = rTime > lTime ? r : l
                if mc.translation == nil { mc.translation = l.translation ?? r.translation }
                var combinedComments: [String] = []
                for cm in (l.comments + r.comments) where !combinedComments.contains(cm) {
                    combinedComments.append(cm)
                }
                mc.comments = combinedComments
                cardsById[r.id] = mc
            } else {
                cardsById[r.id] = r
                cardOrder.append(r.id)
            }
        }
        out.cards = cardOrder.compactMap { cardsById[$0] }
        let validCardIds = Set(out.cards.map(\.id))

        // 3. Merge Notebooks
        var notebooksById: [UUID: Notebook] = [:]
        var nbOrder: [UUID] = []
        for nb in local.notebooks where !deleted.contains(nb.id) {
            notebooksById[nb.id] = nb
            nbOrder.append(nb.id)
        }
        for r in remote.notebooks where !deleted.contains(r.id) {
            if let l = notebooksById[r.id] {
                var mnb = l
                // Union docIds preserving order
                var combinedDocs = l.docIds.filter { validDocIds.contains($0) }
                for id in r.docIds where validDocIds.contains(id) && !combinedDocs.contains(id) {
                    combinedDocs.append(id)
                }
                mnb.docIds = combinedDocs
                mnb.root = mergeMindNodes(local: l.root, remote: r.root, deleted: deleted, validCards: validCardIds)
                if mnb.root.title != mnb.name && !r.name.isEmpty {
                    mnb.name = mnb.root.title
                }
                notebooksById[r.id] = mnb
            } else {
                // If local only has an untouched empty default notebook and remote has a populated default notebook, merge into one
                if let emptyLocalIdx = nbOrder.firstIndex(where: {
                    guard let existing = notebooksById[$0] else { return false }
                    return existing.docIds.isEmpty && existing.root.children.isEmpty && (existing.name == "我的笔记本" || existing.name == "My Notebook")
                }), (r.name == "我的笔记本" || r.name == "My Notebook") {
                    let oldId = nbOrder[emptyLocalIdx]
                    notebooksById.removeValue(forKey: oldId)
                    var cleanR = r
                    cleanR.docIds = r.docIds.filter { validDocIds.contains($0) }
                    notebooksById[r.id] = cleanR
                    nbOrder[emptyLocalIdx] = r.id
                } else {
                    var cleanR = r
                    cleanR.docIds = r.docIds.filter { validDocIds.contains($0) }
                    notebooksById[r.id] = cleanR
                    nbOrder.append(r.id)
                }
            }
        }
        out.notebooks = nbOrder.compactMap { notebooksById[$0] }
        if out.notebooks.isEmpty {
            let def = Notebook(name: "我的笔记本", docIds: Array(validDocIds), root: MindNode(title: "我的笔记本"))
            out.notebooks = [def]
        } else if !validDocIds.isEmpty {
            // Ensure every synced doc belongs to at least one notebook so it is visible on the bookshelf
            let assigned = Set(out.notebooks.flatMap(\.docIds))
            let unassigned = out.docs.map(\.id).filter { !assigned.contains($0) }
            if !unassigned.isEmpty {
                out.notebooks[0].docIds.append(contentsOf: unassigned)
            }
        }

        // 4. Merge CardLinks
        var linkSet = Set<CardLink>()
        var links: [CardLink] = []
        for lk in (local.links + remote.links) {
            guard validCardIds.contains(lk.a), validCardIds.contains(lk.b), lk.a != lk.b else { continue }
            let rev = CardLink(a: lk.b, b: lk.a)
            if !linkSet.contains(lk) && !linkSet.contains(rev) {
                linkSet.insert(lk)
                links.append(lk)
            }
        }
        out.links = links

        let localData = try? JSONEncoder().encode(local)
        let remoteData = try? JSONEncoder().encode(remote)
        let mergedData = try? JSONEncoder().encode(out)
        let localChanged = localData != mergedData
        let remoteChanged = remoteData != mergedData
        return (out, localChanged, remoteChanged)
    }

    nonisolated private static func mergeMindNodes(
        local: MindNode,
        remote: MindNode,
        deleted: Set<UUID>,
        validCards: Set<UUID>
    ) -> MindNode {
        var result = local
        if result.title.isEmpty && !remote.title.isEmpty {
            result.title = remote.title
        }
        var childById: [UUID: MindNode] = [:]
        var order: [UUID] = []
        for ch in local.children where !deleted.contains(ch.id) {
            if let cid = ch.cardId, !validCards.contains(cid) { continue }
            childById[ch.id] = ch
            order.append(ch.id)
        }
        for rch in remote.children where !deleted.contains(rch.id) {
            if let cid = rch.cardId, !validCards.contains(cid) { continue }
            if let lch = childById[rch.id] {
                childById[rch.id] = mergeMindNodes(local: lch, remote: rch, deleted: deleted, validCards: validCards)
            } else if let cid = rch.cardId, order.contains(where: { childById[$0]?.cardId == cid }) {
                continue
            } else {
                childById[rch.id] = rch
                order.append(rch.id)
            }
        }
        result.children = order.compactMap { childById[$0] }
        return result
    }

    // MARK: - Full Bidirectional Sync Execution

    func syncNow(silent: Bool = false) {
        guard isEnabled else { return }
        if isRunningSync { return }

        let cloudDirs = Self.resolveCloudDirectories()
        let hasKVS = Bundle.main.bundleIdentifier != nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        if let primaryCloud = cloudDirs.first {
            let desc = primaryCloud.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            if cloudLocationDescription != desc { cloudLocationDescription = desc }
        } else if hasKVS {
            let desc = "iCloud (io.novarock.readlet)"
            if cloudLocationDescription != desc { cloudLocationDescription = desc }
        } else {
            state = .unavailable("未检测到 iCloud Drive 目录")
            return
        }
        isRunningSync = true
        if !silent || lastSyncedAt == nil {
            state = .syncing
        }

        let currentLib = Store.shared.lib
        let localBase = Paths.base
        let localSettings = captureCurrentSettings()
        if hasKVS && !silent {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        let kvsLibData = hasKVS ? NSUbiquitousKeyValueStore.default.data(forKey: "readlet.kvs.library") : nil
        let kvsTombData = hasKVS ? NSUbiquitousKeyValueStore.default.data(forKey: "readlet.kvs.tombstones") : nil
        let kvsSetData = hasKVS ? NSUbiquitousKeyValueStore.default.data(forKey: "readlet.cloud.settings") : nil

        syncTask?.cancel()
        syncTask = Task {
            defer { self.isRunningSync = false }
            let result = await Task.detached(priority: .utility) { () -> (Library, Bool, CloudSettingsPayload?, Data?, Data?, Data?, String?) in
                let fm = FileManager.default

                // 1. Trigger downloads for any unmaterialized `.icloud` placeholder files (PDFs, JSONs, images)
                for dir in cloudDirs {
                    Self.downloadUbiquitousPlaceholders(in: dir)
                }

                // 2. Merge tombstones across local, KVS, and all cloud directories
                var mergedTombstones = Self.loadTombstones(from: localBase.appendingPathComponent("deleted-items.json"))
                if let td = kvsTombData, let kt = try? JSONDecoder().decode(TombstoneSet.self, from: td) {
                    for (id, dt) in kt.deletedIds {
                        if let existing = mergedTombstones.deletedIds[id] {
                            if dt > existing { mergedTombstones.deletedIds[id] = dt }
                        } else {
                            mergedTombstones.deletedIds[id] = dt
                        }
                    }
                }
                for dir in cloudDirs {
                    let ct = Self.loadTombstones(from: dir.appendingPathComponent("deleted-items.json"))
                    for (id, dt) in ct.deletedIds {
                        if let existing = mergedTombstones.deletedIds[id] {
                            if dt > existing { mergedTombstones.deletedIds[id] = dt }
                        } else {
                            mergedTombstones.deletedIds[id] = dt
                        }
                    }
                }
                let deletedSet = Set(mergedTombstones.deletedIds.keys)
                Self.saveTombstones(mergedTombstones, to: localBase.appendingPathComponent("deleted-items.json"))
                for dir in cloudDirs {
                    Self.saveTombstones(mergedTombstones, to: dir.appendingPathComponent("deleted-items.json"))
                }
                let outTombData = try? JSONEncoder().encode(mergedTombstones)

                // 3. Merge `library.json` across local disk, KVS, and all cloud directories
                var workingLib = currentLib
                var anyLocalChange = false
                let diskLibURL = localBase.appendingPathComponent("library.json")
                if let dd = try? Data(contentsOf: diskLibURL),
                   let diskLib = try? JSONDecoder().decode(Library.self, from: dd) {
                    let (merged, localChanged, _) = Self.mergeLibraries(local: workingLib, remote: diskLib, deleted: deletedSet)
                    if localChanged || merged.docs.count != workingLib.docs.count || merged.cards.count != workingLib.cards.count {
                        anyLocalChange = true
                    }
                    workingLib = merged
                }
                if let kd = kvsLibData, let kvsLib = try? JSONDecoder().decode(Library.self, from: kd) {
                    let (merged, localChanged, _) = Self.mergeLibraries(local: workingLib, remote: kvsLib, deleted: deletedSet)
                    workingLib = merged
                    if localChanged { anyLocalChange = true }
                }
                for dir in cloudDirs {
                    let cloudLibURL = dir.appendingPathComponent("library.json")
                    if let d = try? Data(contentsOf: cloudLibURL),
                       let remoteLib = try? JSONDecoder().decode(Library.self, from: d) {
                        let (merged, localChanged, _) = Self.mergeLibraries(local: workingLib, remote: remoteLib, deleted: deletedSet)
                        workingLib = merged
                        if localChanged { anyLocalChange = true }
                    }
                }

                // Also discover any standalone `docs/<UUID>/original.pdf` in localBase or cloud dirs that weren't in library.json yet
                for dir in ([localBase] + cloudDirs) {
                    let docsRoot = dir.appendingPathComponent("docs", isDirectory: true)
                    if let entries = try? fm.contentsOfDirectory(at: docsRoot, includingPropertiesForKeys: nil) {
                        for entry in entries {
                            guard let docId = UUID(uuidString: entry.lastPathComponent),
                                  !deletedSet.contains(docId),
                                  !workingLib.docs.contains(where: { $0.id == docId }) else { continue }
                            let pdfURL = entry.appendingPathComponent("original.pdf")
                            if let pdf = PDFDocument(url: pdfURL) {
                                let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "Synced PDF \(docId.uuidString.prefix(6))"
                                let newDoc = Doc(id: docId, title: title, tags: [DocStatusTag.todo.rawValue], pageCount: pdf.pageCount)
                                workingLib.docs.append(newDoc)
                                if !workingLib.notebooks.isEmpty {
                                    workingLib.notebooks[0].docIds.append(docId)
                                }
                                anyLocalChange = true
                            }
                        }
                    }
                }

                // 4. Write merged `library.json` back to all cloud directories and local only if changed
                let encodedLib = try? JSONEncoder().encode(workingLib)
                if let encodedLib {
                    Self.writeDataIfChanged(encodedLib, to: localBase.appendingPathComponent("library.json"))
                    for dir in cloudDirs {
                        Self.writeDataIfChanged(encodedLib, to: dir.appendingPathComponent("library.json"))
                    }
                }

                // 5. Sync document files (`original.pdf`, `thumb.png`, `narration/*.json`, `trans.json`, `chat.json`, `flashcards.json`).
                // Audio files (`*.m4a`, `*.wav`) and rendered bilingual caches (`bi2-*`) are kept strictly local!
                for docIdx in workingLib.docs.indices {
                    let doc = workingLib.docs[docIdx]
                    let localDocDir = localBase.appendingPathComponent("docs/\(doc.id.uuidString)", isDirectory: true)
                    try? fm.createDirectory(at: localDocDir, withIntermediateDirectories: true)
                    let lNarr = localDocDir.appendingPathComponent("narration", isDirectory: true)
                    let lProgURL = lNarr.appendingPathComponent("progress.json")

                    if let np = doc.narrationPage, (np > 0 || (doc.narrationSeg ?? 0) > 0) {
                        let existing = (try? Data(contentsOf: lProgURL)).flatMap { try? JSONDecoder().decode(Narrator.Progress.self, from: $0) }
                        let existingNonZero = (existing?.page ?? 0) > 0 || (existing?.seg ?? 0) > 0
                        if !existingNonZero || (doc.narrationUpdatedAt ?? .distantPast) > (existing?.date ?? .distantPast) {
                            try? fm.createDirectory(at: lNarr, withIntermediateDirectories: true)
                            let p = Narrator.Progress(page: np, seg: doc.narrationSeg ?? 0, date: doc.narrationUpdatedAt ?? Date())
                            if let d = try? JSONEncoder().encode(p) {
                                Self.writeDataIfChanged(d, to: lProgURL)
                            }
                        }
                    }

                    for dir in cloudDirs {
                        let cloudDocDir = dir.appendingPathComponent("docs/\(doc.id.uuidString)", isDirectory: true)
                        try? fm.createDirectory(at: cloudDocDir, withIntermediateDirectories: true)

                        // Sync PDF + thumbnail + lightweight JSON files (never audio or video!)
                        for fileName in ["original.pdf", "thumb.png", "flashcards.json", "trans.json", "chat.json"] {
                            let lFile = localDocDir.appendingPathComponent(fileName)
                            let cFile = cloudDocDir.appendingPathComponent(fileName)
                            Self.syncFileBidirectional(local: lFile, cloud: cFile)
                        }

                        // Sync narration scripts & progress (`*.json` only), and migrate any legacy cloud audio/bilingual caches to local before purging from iCloud!
                        let cNarr = cloudDocDir.appendingPathComponent("narration", isDirectory: true)
                        Self.syncDirectoryFilesBidirectional(localDir: lNarr, cloudDir: cNarr, extensions: ["json"])
                        if dir.standardizedFileURL.path.contains("Mobile Documents") || dir.standardizedFileURL.path.contains("iCloud") {
                            Self.purgeAudioClipsFromCloud(cloudDir: cNarr, migrateToLocalDir: lNarr)
                            Self.migrateAndPurgeBilingualFromCloud(cloudDocDir: cloudDocDir, localDocDir: localDocDir)
                        }
                    }

                    if workingLib.docs[docIdx].pageCount == nil,
                       let pdf = PDFDocument(url: localDocDir.appendingPathComponent("original.pdf")) {
                        workingLib.docs[docIdx].pageCount = pdf.pageCount
                        anyLocalChange = true
                    }

                    if let syncedProgData = try? Data(contentsOf: lProgURL),
                       let syncedProg = try? JSONDecoder().decode(Narrator.Progress.self, from: syncedProgData),
                       (syncedProg.page > 0 || syncedProg.seg > 0) {
                        let curNonZero = (workingLib.docs[docIdx].narrationPage ?? 0) > 0 || (workingLib.docs[docIdx].narrationSeg ?? 0) > 0
                        if !curNonZero || syncedProg.date > (workingLib.docs[docIdx].narrationUpdatedAt ?? .distantPast) {
                            workingLib.docs[docIdx].narrationPage = syncedProg.page
                            workingLib.docs[docIdx].narrationSeg = syncedProg.seg
                            workingLib.docs[docIdx].narrationUpdatedAt = syncedProg.date
                            anyLocalChange = true
                        }
                    }
                }

                // Clean up deleted document directories in cloud
                for deletedId in deletedSet {
                    for dir in cloudDirs {
                        let deadDir = dir.appendingPathComponent("docs/\(deletedId.uuidString)", isDirectory: true)
                        if fm.fileExists(atPath: deadDir.path) {
                            try? fm.removeItem(at: deadDir)
                        }
                    }
                }

                // 6. Sync card image excerpts (`images/<UUID>.png`), `flashcards.json`, `copilot.json`, `translations.json`
                let lImages = localBase.appendingPathComponent("images", isDirectory: true)
                for dir in cloudDirs {
                    let cImages = dir.appendingPathComponent("images", isDirectory: true)
                    Self.syncDirectoryFilesBidirectional(localDir: lImages, cloudDir: cImages, extensions: ["png", "jpg"])
                    for rootFile in ["flashcards.json", "copilot.json", "translations.json"] {
                        Self.syncFileBidirectional(
                            local: localBase.appendingPathComponent(rootFile),
                            cloud: dir.appendingPathComponent(rootFile)
                        )
                    }
                }

                // 7. Sync Gateway & TTS Settings (`cloud-settings.json` + KVS + localBase bootstrap)
                var newerRemoteSettings: CloudSettingsPayload? = nil
                var bestSettings = localSettings
                var candidateSettingsData: [Data] = []
                if let sd = kvsSetData { candidateSettingsData.append(sd) }
                if let ld = try? Data(contentsOf: localBase.appendingPathComponent("cloud-settings.json")) {
                    candidateSettingsData.append(ld)
                }
                for dir in cloudDirs {
                    if let cd = try? Data(contentsOf: dir.appendingPathComponent("cloud-settings.json")) {
                        candidateSettingsData.append(cd)
                    }
                }
                for d in candidateSettingsData {
                    if let remoteSet = try? JSONDecoder().decode(CloudSettingsPayload.self, from: d) {
                        let localHasKey = !(bestSettings.apiKey ?? "").isEmpty
                        let remoteHasKey = !(remoteSet.apiKey ?? "").isEmpty
                        if remoteSet.updatedAt > bestSettings.updatedAt && (remoteHasKey || !localHasKey) {
                            bestSettings = remoteSet
                            newerRemoteSettings = remoteSet
                        } else if !localHasKey && remoteHasKey {
                            if bestSettings.updatedAt <= Date(timeIntervalSince1970: 1) {
                                bestSettings = remoteSet
                                newerRemoteSettings = remoteSet
                            } else {
                                bestSettings.apiKey = remoteSet.apiKey
                            }
                        }
                    }
                }
                let encodedSet = try? JSONEncoder().encode(bestSettings)
                if let encodedSet {
                    Self.writeDataIfChanged(encodedSet, to: localBase.appendingPathComponent("cloud-settings.json"))
                    for dir in cloudDirs {
                        Self.writeDataIfChanged(encodedSet, to: dir.appendingPathComponent("cloud-settings.json"))
                    }
                }

                #if os(macOS)
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                    Self.syncWithConnectedIOSDevice(
                        localBase: localBase,
                        cloudDirs: cloudDirs,
                        workingLib: &workingLib,
                        deletedSet: deletedSet,
                        anyLocalChange: &anyLocalChange
                    )
                }
                #endif

                let finalEncodedLib = try? JSONEncoder().encode(workingLib)
                return (workingLib, anyLocalChange, newerRemoteSettings, finalEncodedLib, outTombData, encodedSet, nil)
            }.value

            let (mergedLib, localChanged, remoteSettings, outLibData, outTombData, outSetData, err) = result
            if hasKVS {
                var kvsModified = false
                if let outLibData, outLibData.count < 500_000, outLibData != kvsLibData {
                    NSUbiquitousKeyValueStore.default.set(outLibData, forKey: "readlet.kvs.library")
                    kvsModified = true
                }
                if let outTombData, outTombData.count < 100_000, outTombData != kvsTombData {
                    NSUbiquitousKeyValueStore.default.set(outTombData, forKey: "readlet.kvs.tombstones")
                    kvsModified = true
                }
                if let outSetData, outSetData != kvsSetData {
                    NSUbiquitousKeyValueStore.default.set(outSetData, forKey: "readlet.cloud.settings")
                    kvsModified = true
                }
                if kvsModified {
                    NSUbiquitousKeyValueStore.default.synchronize()
                }
            }
            if let err {
                self.state = .error(err)
                return
            }

            self.isApplyingRemoteChanges = true
            defer { self.isApplyingRemoteChanges = false }

            if let remoteSettings {
                self.applyRemoteSettings(remoteSettings)
            }

            if localChanged {
                Store.shared.applyCloudMergedLibrary(mergedLib)
            }

            let now = Date()
            if !silent || localChanged || remoteSettings != nil || self.lastSyncedAt == nil {
                self.lastSyncedAt = now
                self.syncedDocsCount = Store.shared.lib.docs.count
                self.syncedCardsCount = Store.shared.lib.cards.count
                UserDefaults.standard.set(now, forKey: "icloud.sync.lastDate")
                self.state = .synced(now)
            }
        }
    }

    // MARK: - File Sync Helpers

    nonisolated private static func downloadUbiquitousPlaceholders(in root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                // Never download audio clips from iCloud; delete audio placeholders instead
                if name.hasSuffix(".m4a.icloud") || name.hasSuffix(".wav.icloud") {
                    try? fm.removeItem(at: fileURL)
                } else {
                    try? fm.startDownloadingUbiquitousItem(at: fileURL)
                }
            }
        }
    }

    /// Migrates any materialized `.m4a` / `.wav` audio files from an iCloud `narration/` directory into `migrateToLocalDir`
    /// (if not already present locally), and then removes them from iCloud so audio stays strictly local.
    nonisolated static func purgeAudioClipsFromCloud(cloudDir: URL, migrateToLocalDir: URL? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil) else { return }
        var createdLocal = false
        for f in files {
            let name = f.lastPathComponent
            let ext = f.pathExtension.lowercased()
            if ext == "m4a" || ext == "wav" {
                if let localDir = migrateToLocalDir, isValidSyncFile(f) {
                    let localFile = localDir.appendingPathComponent(name)
                    if !isValidSyncFile(localFile) {
                        if !createdLocal {
                            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
                            createdLocal = true
                        }
                        atomicCopy(from: f, to: localFile)
                    }
                }
                try? fm.removeItem(at: f)
            } else if name.hasSuffix(".m4a.icloud") || name.hasSuffix(".wav.icloud") {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// Migrates any legacy `bi2-*` rendered bilingual PDF page caches from iCloud to local storage on upgrade, then removes them from iCloud.
    nonisolated static func migrateAndPurgeBilingualFromCloud(cloudDocDir: URL, localDocDir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cloudDocDir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("bi2-") {
            let localTarget = localDocDir.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: localTarget.path) {
                try? fm.createDirectory(at: localDocDir, withIntermediateDirectories: true)
                try? fm.moveItem(at: item, to: localTarget)
            } else {
                if let pages = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    for p in pages where p.pathExtension.lowercased() == "pdf" && isValidSyncFile(p) {
                        let lp = localTarget.appendingPathComponent(p.lastPathComponent)
                        if !isValidSyncFile(lp) {
                            atomicCopy(from: p, to: lp)
                        }
                    }
                }
                try? fm.removeItem(at: item)
            }
        }
    }

    nonisolated private static func isValidSyncFile(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let sz = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int),
              sz > 0 else { return false }
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url) != nil
        }
        return true
    }

    nonisolated private static func atomicCopy(from src: URL, to dst: URL) {
        let fm = FileManager.default
        let parent = dst.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(dst.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: tmp) }
        guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return }
        if fm.fileExists(atPath: dst.path) {
            _ = try? fm.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try? fm.moveItem(at: tmp, to: dst)
        }
    }

    nonisolated static func syncFileBidirectional(local: URL, cloud: URL) {
        let fm = FileManager.default
        let cloudPlaceholder = cloud.deletingLastPathComponent().appendingPathComponent(".\(cloud.lastPathComponent).icloud")
        if fm.fileExists(atPath: cloudPlaceholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: cloudPlaceholder)
        }

        let lValid = isValidSyncFile(local)
        let cValid = isValidSyncFile(cloud)

        if lValid && !cValid {
            // Do not overwrite an unmaterialized cloud placeholder unless local is a valid file ready to upload
            atomicCopy(from: local, to: cloud)
        } else if !lValid && cValid {
            atomicCopy(from: cloud, to: local)
        } else if lValid && cValid {
            let lAttr = try? fm.attributesOfItem(atPath: local.path)
            let cAttr = try? fm.attributesOfItem(atPath: cloud.path)
            let lDate = (lAttr?[.modificationDate] as? Date) ?? .distantPast
            let cDate = (cAttr?[.modificationDate] as? Date) ?? .distantPast
            let lSize = (lAttr?[.size] as? Int) ?? 0
            let cSize = (cAttr?[.size] as? Int) ?? 0
            guard lSize != cSize || abs(lDate.timeIntervalSince(cDate)) > 2.0 else { return }
            if lDate > cDate {
                atomicCopy(from: local, to: cloud)
            } else if cDate > lDate {
                atomicCopy(from: cloud, to: local)
            }
        }
    }

    nonisolated static func syncDirectoryFilesBidirectional(localDir: URL, cloudDir: URL, extensions: [String]) {
        let fm = FileManager.default
        let lFiles = (try? fm.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)) ?? []
        let cFiles = (try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil)) ?? []
        var allNames = Set<String>()
        for u in lFiles + cFiles {
            let name = u.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                try? fm.startDownloadingUbiquitousItem(at: u)
                continue
            }
            let ext = u.pathExtension.lowercased()
            if extensions.isEmpty || extensions.contains(ext) {
                allNames.insert(name)
            }
        }
        guard !allNames.isEmpty else { return }
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        for name in allNames {
            syncFileBidirectional(
                local: localDir.appendingPathComponent(name),
                cloud: cloudDir.appendingPathComponent(name)
            )
        }
    }

    // MARK: - Gateway & TTS Settings Sync

    func recordSettingsChange() {
        UserDefaults.standard.set(Date(), forKey: "icloud.settings.updatedAt")
        notifyLocalChange()
    }

    private func captureCurrentSettings() -> CloudSettingsPayload {
        let updatedAt = (UserDefaults.standard.object(forKey: "icloud.settings.updatedAt") as? Date)
            ?? (try? FileManager.default.attributesOfItem(atPath: ConfigFile.url.path)[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)
        let key = Settings.apiKey
        var pVoices: [String: String] = [:]
        var pModels: [String: String] = [:]
        var pBases: [String: String] = [:]
        for p in TTSProvider.allCases where p.isRemote {
            let v = Settings.ttsVoice(p)
            if !v.isEmpty { pVoices[p.rawValue] = v }
            let m = Settings.ttsModel(p)
            if !m.isEmpty { pModels[p.rawValue] = m }
            if p != .gateway {
                let b = Settings.ttsBaseURLOverride(p)
                if !b.isEmpty { pBases[p.rawValue] = b }
            }
        }
        return CloudSettingsPayload(
            updatedAt: updatedAt,
            baseURL: Settings.baseURL,
            model: Settings.model,
            translateModel: ModelConfig.translateModel,
            translateProtocol: ModelConfig.style("translate").rawValue,
            assistantModel: ModelConfig.chatModel,
            assistantProtocol: ModelConfig.style("chat").rawValue,
            targetLang: Settings.targetLang,
            ttsProvider: Settings.ttsProvider.rawValue,
            ttsVoice: Settings.ttsVoice,
            ttsSpeed: Settings.ttsSpeed,
            narrationStyle: Settings.narrationStyle.rawValue,
            narrationExtraPrompt: Settings.narrationExtraPrompt,
            apiKey: key.isEmpty ? nil : key,
            systemVoice: Settings.systemVoice,
            ttsRegion: Settings.ttsRegion.isEmpty ? nil : Settings.ttsRegion,
            ttsAppId: Settings.ttsAppId.isEmpty ? nil : Settings.ttsAppId,
            providerVoices: pVoices.isEmpty ? nil : pVoices,
            providerModels: pModels.isEmpty ? nil : pModels,
            providerBaseURLs: pBases.isEmpty ? nil : pBases
        )
    }

    private func applyRemoteSettings(_ s: CloudSettingsPayload) {
        if !s.baseURL.isEmpty { Settings.baseURL = s.baseURL }
        if !s.model.isEmpty { Settings.model = s.model }
        if !s.translateModel.isEmpty { ModelConfig.setModel("translate", s.translateModel) }
        if let p = APIStyle(rawValue: s.translateProtocol) { ModelConfig.setStyle("translate", p) }
        if !s.assistantModel.isEmpty { ModelConfig.setModel("chat", s.assistantModel) }
        if let p = APIStyle(rawValue: s.assistantProtocol) { ModelConfig.setStyle("chat", p) }
        if !s.targetLang.isEmpty { Settings.targetLang = s.targetLang }
        if let pVoices = s.providerVoices {
            for (raw, v) in pVoices where !v.isEmpty {
                if let p = TTSProvider(rawValue: raw) { Settings.setTTSVoice(v, p) }
            }
        }
        if let pModels = s.providerModels {
            for (raw, m) in pModels where !m.isEmpty {
                if let p = TTSProvider(rawValue: raw) { Settings.setTTSModel(m, p) }
            }
        }
        if let pBases = s.providerBaseURLs {
            for (raw, b) in pBases {
                if let p = TTSProvider(rawValue: raw), p != .gateway { Settings.setTTSBaseURL(b, p) }
            }
        }
        if let reg = s.ttsRegion, !reg.isEmpty { Settings.ttsRegion = reg }
        if let app = s.ttsAppId, !app.isEmpty { Settings.ttsAppId = app }
        if let sysV = s.systemVoice {
            Settings.systemVoice = sysV
            Narrator.shared.systemVoice = sysV
        }
        if let tp = TTSProvider(rawValue: s.ttsProvider) {
            Settings.ttsProvider = tp
            Narrator.shared.provider = tp
        }
        if !s.ttsVoice.isEmpty {
            Settings.ttsVoice = s.ttsVoice
            Narrator.shared.voice = s.ttsVoice
        }
        if s.ttsSpeed > 0 {
            Settings.ttsSpeed = s.ttsSpeed
            Narrator.shared.rate = s.ttsSpeed
        }
        if let st = NarrationStyle(rawValue: s.narrationStyle) { Settings.narrationStyle = st }
        Settings.narrationExtraPrompt = s.narrationExtraPrompt
        if let k = s.apiKey, !k.isEmpty, Settings.apiKey.isEmpty {
            Settings.apiKey = k
        }
        UserDefaults.standard.set(s.updatedAt, forKey: "icloud.settings.updatedAt")
    }

    #if os(macOS)
    nonisolated private static func runDeviceCtl(_ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["devicectl"] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return (-1, "") }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out)
    }

    nonisolated private static func syncWithConnectedIOSDevice(
        localBase: URL,
        cloudDirs: [URL],
        workingLib: inout Library,
        deletedSet: Set<UUID>,
        anyLocalChange: inout Bool
    ) {
        let fm = FileManager.default
        let (status, out) = runDeviceCtl(["list", "devices"])
        guard status == 0, !out.isEmpty else { return }

        var deviceIds: [String] = []
        for line in out.split(separator: "\n")
        where (line.contains("connected") || line.contains("available")) && (line.contains("iPhone") || line.contains("iPad")) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for p in parts where p.count == 36 && p.filter({ $0 == "-" }).count == 4 {
                deviceIds.append(p)
            }
        }
        guard let devId = deviceIds.first else { return }

        let tmpPull = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("readlet-ios-pull-\(devId).json")
        try? fm.removeItem(at: tmpPull)
        _ = runDeviceCtl([
            "device", "copy", "from",
            "--device", devId,
            "--domain-type", "appDataContainer",
            "--domain-identifier", "io.novarock.readlet",
            "--source", "Library/Application Support/Readlet/library.json",
            "--destination", tmpPull.path
        ])

        var deviceHadLib = false
        var remoteNeedsUpdate = true
        if let d = try? Data(contentsOf: tmpPull),
           let iosLib = try? JSONDecoder().decode(Library.self, from: d) {
            deviceHadLib = true
            let (merged, localChanged, remoteChanged) = mergeLibraries(local: workingLib, remote: iosLib, deleted: deletedSet)
            workingLib = merged
            if localChanged { anyLocalChange = true }
            remoteNeedsUpdate = remoteChanged
        }
        try? fm.removeItem(at: tmpPull)

        if let encoded = try? JSONEncoder().encode(workingLib) {
            writeDataIfChanged(encoded, to: localBase.appendingPathComponent("library.json"))
            for dir in cloudDirs {
                writeDataIfChanged(encoded, to: dir.appendingPathComponent("library.json"))
            }
        }

        if !deviceHadLib || remoteNeedsUpdate {
            for fn in ["library.json", "cloud-settings.json", "deleted-items.json"] {
                let src = localBase.appendingPathComponent(fn)
                guard fm.fileExists(atPath: src.path) else { continue }
                _ = runDeviceCtl([
                    "device", "copy", "to",
                    "--device", devId,
                    "--domain-type", "appDataContainer",
                    "--domain-identifier", "io.novarock.readlet",
                    "--source", src.path,
                    "--destination", "Library/Application Support/Readlet/\(fn)"
                ])
            }
        }

        // Also ensure PDFs, thumbnails, and narration scripts (never audio!) are synced to the connected iPhone
        let (_, remoteDocsOut) = runDeviceCtl([
            "device", "info", "files",
            "--device", devId,
            "--domain-type", "appDataContainer",
            "--domain-identifier", "io.novarock.readlet",
            "--subdirectory", "Library/Application Support/Readlet/docs"
        ])
        for doc in workingLib.docs {
            let docIdStr = doc.id.uuidString
            let localDocDir = localBase.appendingPathComponent("docs/\(docIdStr)", isDirectory: true)
            let localPDF = localDocDir.appendingPathComponent("original.pdf")
            guard isValidSyncFile(localPDF) else { continue }

            // Check if the device already has `original.pdf` for this doc
            let (_, docFilesOut) = runDeviceCtl([
                "device", "info", "files",
                "--device", devId,
                "--domain-type", "appDataContainer",
                "--domain-identifier", "io.novarock.readlet",
                "--subdirectory", "Library/Application Support/Readlet/docs/\(docIdStr)"
            ])
            let hasRemotePDF = remoteDocsOut.contains(docIdStr) && docFilesOut.contains("original.pdf")
            if !hasRemotePDF {
                // Push clean doc directory (PDF + thumb + narration scripts only, no audio/bi2 caches)
                let stageDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("readlet-stage-\(docIdStr)", isDirectory: true)
                try? fm.removeItem(at: stageDir)
                try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
                for fn in ["original.pdf", "thumb.png", "flashcards.json", "trans.json", "chat.json"] {
                    let s = localDocDir.appendingPathComponent(fn)
                    if fm.fileExists(atPath: s.path) {
                        try? fm.copyItem(at: s, to: stageDir.appendingPathComponent(fn))
                    }
                }
                let lNarr = localDocDir.appendingPathComponent("narration", isDirectory: true)
                if let narrFiles = try? fm.contentsOfDirectory(at: lNarr, includingPropertiesForKeys: nil) {
                    let sNarr = stageDir.appendingPathComponent("narration", isDirectory: true)
                    try? fm.createDirectory(at: sNarr, withIntermediateDirectories: true)
                    for nf in narrFiles where nf.pathExtension.lowercased() == "json" {
                        try? fm.copyItem(at: nf, to: sNarr.appendingPathComponent(nf.lastPathComponent))
                    }
                }
                _ = runDeviceCtl([
                    "device", "copy", "to",
                    "--device", devId,
                    "--domain-type", "appDataContainer",
                    "--domain-identifier", "io.novarock.readlet",
                    "--source", stageDir.path,
                    "--destination", "Library/Application Support/Readlet/docs/\(docIdStr)"
                ])
                try? fm.removeItem(at: stageDir)
            }
        }
    }
    #endif
}

