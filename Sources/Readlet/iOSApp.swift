#if os(iOS)
import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

final class iOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return .portrait
        }
        return .all
    }
}

@main
struct ReadletIOSApp: App {
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared
    @StateObject private var cloud = CloudSync.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Migration.run()
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView(store: store, cloud: cloud)
                .onAppear {
                    cloud.start()
                }
                .onOpenURL { url in
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    if url.pathExtension.lowercased() == "pdf" {
                        if let id = store.importPDF(url, open: true) {
                            DocWindows.shared.open(id)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        cloud.syncNow(silent: true)
                    } else if newPhase == .background {
                        store.saveNow()
                    }
                }
        }
    }
}

@MainActor
final class iOSThemeCenter: ObservableObject {
    static let shared = iOSThemeCenter()
    @Published var theme: AppTheme = AppTheme.current
    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }
    func set(_ t: AppTheme) {
        UserDefaults.standard.set(t.rawValue, forKey: "theme")
        theme = t
    }
}

// MARK: - Root Tab View

struct iOSRootView: View {
    @ObservedObject var store: Store
    @ObservedObject var cloud: CloudSync
    @ObservedObject var wins = DocWindows.shared
    @ObservedObject var lang = LangCenter.shared
    @ObservedObject var themeCenter = iOSThemeCenter.shared
    @ObservedObject var narrator = Narrator.shared

    @State private var selectedTab = 0
    @State private var activeReaderDocId: UUID?

    var body: some View {
        ZStack {
            if let docId = activeReaderDocId, store.doc(docId) != nil {
                iOSDocumentStudyView(
                    store: store,
                    docId: docId,
                    onClose: { activeReaderDocId = nil },
                    onSwitchDoc: { targetId in
                        DocWindows.shared.open(targetId)
                        activeReaderDocId = targetId
                    }
                )
                .id(docId)
            } else {
                ZStack(alignment: .bottom) {
                    TabView(selection: $selectedTab) {
                        iOSBookshelfView(
                            store: store,
                            cloud: cloud,
                            onOpenDoc: { id in
                                DocWindows.shared.open(id)
                                activeReaderDocId = id
                            },
                            onOpenNotebookMindMap: { nbId in
                                store.currentNotebookId = nbId
                                selectedTab = 1
                            }
                        )
                        .tabItem {
                            Label(L("书架"), systemImage: "books.vertical.fill")
                        }
                        .tag(0)

                        iOSMindMapTabView(
                            store: store,
                            onJumpToDoc: { id in
                                DocWindows.shared.open(id)
                                activeReaderDocId = id
                            }
                        )
                        .tabItem {
                            Label(L("脑图"), systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .tag(1)

                        iOSFlashcardsTabView(store: store)
                        .tabItem {
                            Label(L("闪卡"), systemImage: "rectangle.on.rectangle.angled")
                        }
                        .tag(2)

                        iOSSettingsView(store: store, cloud: cloud)
                        .tabItem {
                            Label(L("设置与同步"), systemImage: "icloud.and.arrow.up")
                        }
                        .tag(3)
                    }

                    if narrator.state != .idle, let nDocId = narrator.docId, store.doc(nDocId) != nil {
                        iOSPodcastMiniPlayerBar(
                            store: store,
                            narrator: narrator,
                            onOpenNarratedDoc: {
                                DocWindows.shared.open(nDocId)
                                activeReaderDocId = nDocId
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .tint(MN.accent)
        .preferredColorScheme(themeCenter.colorScheme)
        .environment(\.colorScheme, themeCenter.colorScheme)
        .id("\(lang.lang.rawValue)-\(themeCenter.theme.rawValue)")
        .onChange(of: store.pendingJump) { _, card in
            if let card {
                DocWindows.shared.open(card.docId, jump: card)
                activeReaderDocId = card.docId
                store.pendingJump = nil
            }
        }
        .onOpenURL { url in
            if url.scheme == "readlet" {
                let host = url.host() ?? ""
                let path = url.pathComponents.dropFirst().first ?? ""
                if host == "tab", let t = Int(path) {
                    activeReaderDocId = nil
                    selectedTab = t
                } else if host == "open" {
                    if path == "first", let first = store.lib.docs.first {
                        DocWindows.shared.open(first.id)
                        activeReaderDocId = first.id
                    } else if path == "second", store.lib.docs.count > 1 {
                        let second = store.lib.docs[1]
                        DocWindows.shared.open(second.id)
                        activeReaderDocId = second.id
                    } else if let id = UUID(uuidString: path), store.doc(id) != nil {
                        DocWindows.shared.open(id)
                        activeReaderDocId = id
                    }
                } else if host == "narrate" {
                    if let docId = activeReaderDocId, let ses = store.session(docId) {
                        let rc = ReaderController.shared
                        Narrator.shared.start(docId: docId, doc: ses.document(rc.variant), title: ses.doc.title, from: rc.currentPageIndex, resume: false)
                    }
                } else if host == "next-seg" {
                    Narrator.shared.next()
                } else if host == "close" {
                    activeReaderDocId = nil
                }
            }
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "--theme"), idx + 1 < args.count, let t = AppTheme(rawValue: args[idx + 1]) {
                themeCenter.set(t)
            }
            if let idx = args.firstIndex(of: "--tab"), idx + 1 < args.count, let t = Int(args[idx + 1]) {
                selectedTab = t
            }
            if args.contains("--open-first"), let first = store.lib.docs.first {
                DocWindows.shared.open(first.id)
                activeReaderDocId = first.id
            } else if args.contains("--open-second"), store.lib.docs.count > 1 {
                let second = store.lib.docs[1]
                DocWindows.shared.open(second.id)
                activeReaderDocId = second.id
            }
            if args.contains("--podcast-first") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let first = store.lib.docs.first, let ses = store.session(first.id) {
                        Narrator.shared.start(docId: first.id, doc: ses.original, title: first.title, from: first.resolvedReadPage ?? 0, resume: true)
                    }
                }
            }
        }
    }
}

// MARK: - Tab 1: Bookshelf View

struct iOSBookshelfView: View {
    @ObservedObject var store: Store
    @ObservedObject var cloud: CloudSync
    @ObservedObject var lang = LangCenter.shared
    @ObservedObject var themeCenter = iOSThemeCenter.shared
    let onOpenDoc: (UUID) -> Void
    var onOpenNotebookMindMap: ((UUID) -> Void)? = nil

    @State private var selectedNotebookId: UUID? = nil
    @State private var selectedTagFilter: String = "ALL"
    @State private var showFileImporter = false
    @State private var showWebImportSheet = false
    @State private var showNewTagAlert = false
    @State private var tagTargetDocId: UUID?
    @State private var newTagText = ""
    @State private var showNewNotebookAlert = false
    @State private var newNotebookName = ""
    @State private var showRenameNotebookAlert = false
    @State private var renamingNotebookId: UUID?
    @State private var renameNotebookText = ""
    @State private var managingNotebookId: UUID?
    @State private var progressHistoryDocId: UUID?
    @State private var searchText = ""

    private var activeNotebook: Notebook? {
        guard let nbId = selectedNotebookId else { return nil }
        return store.lib.notebooks.first { $0.id == nbId }
    }

    private var notebookScopedDocs: [Doc] {
        if let nb = activeNotebook {
            let idSet = Set(nb.docIds)
            return store.lib.docs.filter { idSet.contains($0.id) }
        }
        return store.lib.docs
    }

    private var filteredDocs: [Doc] {
        let pool = notebookScopedDocs
        let base: [Doc]
        switch selectedTagFilter {
        case "ALL":
            base = pool
        case "UNTAGGED":
            base = pool.filter { $0.tags.isEmpty }
        default:
            base = pool.filter { d in
                d.tags.contains { $0.caseInsensitiveCompare(selectedTagFilter) == .orderedSame }
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    iCloudBanner
                    notebookShelfStrip
                    workflowRatioCard
                    if filteredDocs.isEmpty {
                        emptyStateView
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 16) {
                            ForEach(filteredDocs) { doc in
                                iOSDocCardView(
                                    store: store,
                                    doc: doc,
                                    activeNotebookId: selectedNotebookId,
                                    onTap: {
                                        if let nbId = selectedNotebookId {
                                            store.currentNotebookId = nbId
                                        }
                                        onOpenDoc(doc.id)
                                    },
                                    onAddCustomTag: {
                                        tagTargetDocId = doc.id
                                        newTagText = ""
                                        showNewTagAlert = true
                                    },
                                    onOpenProgressHistory: {
                                        progressHistoryDocId = doc.id
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(MN.shelf)
            .navigationTitle("Readlet")
            .searchable(text: $searchText, prompt: L("搜索 PDF 文档…"))
            .refreshable {
                cloud.syncNow(silent: false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        cloud.syncNow(silent: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.icloud.fill")
                                .font(.subheadline)
                            Text("iCloud")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(MN.accent)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Section(L("语言")) {
                            ForEach(UILang.allCases) { l in
                                Button {
                                    lang.set(l)
                                } label: {
                                    if lang.lang == l {
                                        Label(l.name, systemImage: "checkmark")
                                    } else {
                                        Text(l.name)
                                    }
                                }
                            }
                        }
                        Section(L("界面主题")) {
                            ForEach(AppTheme.allCases) { t in
                                Button {
                                    themeCenter.set(t)
                                } label: {
                                    if themeCenter.theme == t {
                                        Label(t.name, systemImage: "checkmark")
                                    } else {
                                        Text(t.name)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "globe")
                    }

                    Menu {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label(L("导入 PDF 文件…"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            showWebImportSheet = true
                        } label: {
                            Label(L("从网页链接导入…"), systemImage: "globe")
                        }
                        Button {
                            newNotebookName = ""
                            showNewNotebookAlert = true
                        } label: {
                            Label(L("新建笔记本…"), systemImage: "book.closed")
                        }
                        Divider()
                        Button {
                            cloud.syncNow(silent: false)
                        } label: {
                            Label(L("立即同步 iCloud"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                if let nbId = selectedNotebookId {
                    store.currentNotebookId = nbId
                }
                for u in urls {
                    _ = u.startAccessingSecurityScopedResource()
                    defer { u.stopAccessingSecurityScopedResource() }
                    if let id = store.importPDF(u, open: false) {
                        if let nbId = selectedNotebookId {
                            store.addDocToNotebook(id, notebook: nbId)
                        }
                        if urls.count == 1 { onOpenDoc(id) }
                    }
                }
            }
            .sheet(isPresented: $showWebImportSheet) {
                iOSWebImportSheet { importedDocId in
                    if let id = importedDocId {
                        if let nbId = selectedNotebookId {
                            store.addDocToNotebook(id, notebook: nbId)
                        }
                        onOpenDoc(id)
                    }
                }
                .preferredColorScheme(themeCenter.colorScheme)
            }
            .sheet(isPresented: Binding(
                get: { managingNotebookId != nil },
                set: { if !$0 { managingNotebookId = nil } }
            )) {
                if let nbId = managingNotebookId {
                    iOSNotebookDocsSheet(store: store, notebookId: nbId)
                        .preferredColorScheme(themeCenter.colorScheme)
                }
            }
            .sheet(isPresented: Binding(
                get: { progressHistoryDocId != nil },
                set: { if !$0 { progressHistoryDocId = nil } }
            )) {
                if let docId = progressHistoryDocId {
                    iOSDocProgressHistorySheet(store: store, docId: docId, onJumpToPage: { p in
                        progressHistoryDocId = nil
                        store.restoreProgressSnapshot(docId, page: p)
                        onOpenDoc(docId)
                    })
                    .preferredColorScheme(themeCenter.colorScheme)
                }
            }
            .alert(L("添加标签"), isPresented: $showNewTagAlert) {
                TextField(L("标签名称（如 AI、精读）"), text: $newTagText)
                Button(L("取消"), role: .cancel) {}
                Button(L("添加")) {
                    if let id = tagTargetDocId {
                        store.addTag(id, newTagText)
                    }
                }
            }
            .alert(L("新建笔记本"), isPresented: $showNewNotebookAlert) {
                TextField(L("笔记本名称"), text: $newNotebookName)
                Button(L("取消"), role: .cancel) {}
                Button(L("创建")) {
                    let trimmed = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.newNotebook(name: trimmed.isEmpty ? L("新笔记本") : trimmed)
                    selectedNotebookId = store.currentNotebookId
                }
            }
            .alert(L("重命名笔记本"), isPresented: $showRenameNotebookAlert) {
                TextField(L("笔记本名称"), text: $renameNotebookText)
                Button(L("取消"), role: .cancel) {}
                Button(L("保存")) {
                    let trimmed = renameNotebookText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = renamingNotebookId, !trimmed.isEmpty {
                        store.renameNotebook(id, trimmed)
                    }
                }
            }
        }
    }

    private var notebookShelfStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Text(L("笔记本"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let nb = activeNotebook {
                    Button {
                        onOpenNotebookMindMap?(nb.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                            Text(L("查看脑图"))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MN.accent)
                    }
                    .buttonStyle(.plain)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        managingNotebookId = nb.id
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "checklist")
                            Text(L("管理笔记本文档"))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MN.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        newNotebookName = ""
                        showNewNotebookAlert = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text(L("新建笔记本"))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MN.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "All PDFs" pill
                    let allSelected = (selectedNotebookId == nil)
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedNotebookId = nil
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(allSelected ? .white : MN.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L("全部文档"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(allSelected ? .white : .primary)
                                    .lineLimit(1)
                                Text(LF("%d 篇", store.lib.docs.count))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(allSelected ? .white.opacity(0.85) : .secondary)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(allSelected ? MN.accent : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(allSelected ? MN.accent : Color.primary.opacity(0.08), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)

                    // Each Notebook card
                    ForEach(store.lib.notebooks) { nb in
                        let isSelected = (selectedNotebookId == nb.id)
                        let docCount = nb.docIds.filter { store.doc($0) != nil }.count
                        let cardCount = store.lib.cards.filter { nb.docIds.contains($0.docId) }.count
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                if selectedNotebookId == nb.id {
                                    selectedNotebookId = nil
                                } else {
                                    selectedNotebookId = nb.id
                                    store.currentNotebookId = nb.id
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isSelected ? Color.white : Color.orange)
                                    .frame(width: 3.5, height: 24)
                                Image(systemName: "book.closed.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? .white : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(nb.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isSelected ? .white : .primary)
                                        .lineLimit(1)
                                    Text(LF("%d 篇 · %d 卡片", docCount, cardCount))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.orange : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Color.orange : Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                selectedNotebookId = nb.id
                                store.currentNotebookId = nb.id
                            } label: {
                                Label(L("打开"), systemImage: "folder")
                            }
                            Button {
                                onOpenNotebookMindMap?(nb.id)
                            } label: {
                                Label(L("查看脑图"), systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            Button {
                                managingNotebookId = nb.id
                            } label: {
                                Label(L("管理笔记本文档"), systemImage: "checklist")
                            }
                            Button {
                                renamingNotebookId = nb.id
                                renameNotebookText = nb.name
                                showRenameNotebookAlert = true
                            } label: {
                                Label(L("重命名笔记本"), systemImage: "pencil")
                            }
                            if store.lib.notebooks.count > 1 {
                                Divider()
                                Button(role: .destructive) {
                                    if selectedNotebookId == nb.id {
                                        selectedNotebookId = nil
                                    }
                                    store.deleteNotebook(nb.id)
                                } label: {
                                    Label(L("删除笔记本"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
    }

    private var iCloudBannerSubtitle: String {
        if let dt = cloud.lastSyncedAt {
            return LF("已与 Mac 同步 · %@", dt.formatted(date: .omitted, time: .shortened))
        }
        if cloud.state.isSyncing {
            return L("正在与 Mac / iCloud Drive 同步最新阅读进度与文档…")
        }
        return L("Mac 与 iPhone 书架、双语进度、脑图卡片与网关设置自动同步")
    }

    private var iCloudBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 18))
                .foregroundStyle(MN.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L("iCloud 多端自动同步"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(LF("%d PDF · %d 卡片", store.lib.docs.count, store.lib.cards.count))
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MN.accent.opacity(0.12)))
                        .foregroundStyle(MN.accent)
                }
                Text(iCloudBannerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                cloud.syncNow(silent: false)
            } label: {
                ZStack {
                    Circle().fill(MN.accent.opacity(0.12))
                    if cloud.state.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(MN.accent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MN.accent)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
    }

    private var workflowRatioCard: some View {
        let docs = notebookScopedDocs
        let total = max(1, docs.count)
        let todoCount = docs.filter { $0.statusTag == .todo }.count
        let doingCount = docs.filter { $0.statusTag == .doing }.count
        let doneCount = docs.filter { $0.statusTag == .done }.count
        let avgPct = docs.isEmpty ? 0 : Int((docs.map(\.progressFraction).reduce(0, +) / Double(total) * 100).rounded())

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagFilterChip(id: "ALL", title: L("全部"), count: docs.count, color: MN.accent)
                        tagFilterChip(id: "TODO", title: "TODO", count: todoCount, color: .orange)
                        tagFilterChip(id: "DOING", title: "DOING", count: doingCount, color: MN.accent)
                        tagFilterChip(id: "DONE", title: "DONE", count: doneCount, color: .green)
                        ForEach(store.allCustomTags, id: \.self) { ct in
                            let c = docs.filter { d in d.customTags.contains { $0.caseInsensitiveCompare(ct) == .orderedSame } }.count
                            if c > 0 {
                                tagFilterChip(id: ct, title: "#" + ct, count: c, color: .teal)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Text("\(avgPct)%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let todoW = w * CGFloat(todoCount) / CGFloat(total)
                let doingW = w * CGFloat(doingCount) / CGFloat(total)
                let doneW = w * CGFloat(doneCount) / CGFloat(total)
                HStack(spacing: 0) {
                    if todoCount > 0 { Rectangle().fill(Color.orange).frame(width: todoW) }
                    if doingCount > 0 { Rectangle().fill(MN.accent).frame(width: doingW) }
                    if doneCount > 0 { Rectangle().fill(Color.green).frame(width: doneW) }
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: 6)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
    }

    private func tagFilterChip(id: String, title: String, count: Int, color: Color) -> some View {
        let active = selectedTagFilter.caseInsensitiveCompare(id) == .orderedSame
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTagFilter = active && id != "ALL" ? "ALL" : id
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? color : Color.secondary.opacity(0.12)))
            .foregroundStyle(active ? Color.white : color)
        }
        .buttonStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: activeNotebook != nil ? "book.closed" : "doc.richtext")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(activeNotebook != nil ? L("此笔记本还没有文档") : L("暂无匹配的 PDF 文档"))
                .font(.headline)
            Text(L("点击右上角 + 导入 PDF 或网页链接，或在 Mac 上添加文档后通过 iCloud 自动同步到手机。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                if let nb = activeNotebook, !store.lib.docs.isEmpty {
                    Button {
                        managingNotebookId = nb.id
                    } label: {
                        Label(L("添加文档到笔记本…"), systemImage: "checklist")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L("导入 PDF"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MN.accent)
                }

                Button {
                    cloud.syncNow(silent: false)
                } label: {
                    Label(L("同步 iCloud"), systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 16).fill(MN.panel))
    }
}

struct iOSNotebookDocsSheet: View {
    @ObservedObject var store: Store
    let notebookId: UUID
    @Environment(\.dismiss) private var dismiss

    private var notebook: Notebook? {
        store.lib.notebooks.first { $0.id == notebookId }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.lib.docs) { doc in
                    let inNotebook = notebook?.docIds.contains(doc.id) ?? false
                    Button {
                        if inNotebook {
                            store.currentNotebookId = notebookId
                            store.removeDocFromNotebook(doc.id)
                        } else {
                            store.addDocToNotebook(doc.id, notebook: notebookId)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: inNotebook ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(inNotebook ? MN.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let total = doc.pageCount {
                                    Text("p.\(min(total, (doc.resolvedReadPage ?? 0) + 1))/\(total) · \(doc.progressPercent)%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(notebook?.name ?? L("管理笔记本文档"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Bookshelf Document Card & Thumbnail

struct iOSDocCardView: View {
    @ObservedObject var store: Store
    @ObservedObject private var narrator = Narrator.shared
    let doc: Doc
    var activeNotebookId: UUID? = nil
    let onTap: () -> Void
    let onAddCustomTag: () -> Void
    var onOpenProgressHistory: (() -> Void)? = nil

    private var isNarratingThisDoc: Bool {
        narrator.state != .idle && narrator.docId == doc.id
    }

    private func togglePodcastForDoc() {
        if isNarratingThisDoc {
            narrator.togglePause()
        } else if let ses = store.session(doc.id) {
            narrator.start(docId: doc.id, doc: ses.original, title: doc.title, from: doc.resolvedReadPage ?? 0, resume: true)
        }
    }

    private func statusColor(_ st: DocStatusTag?) -> Color {
        switch st {
        case .todo: return .orange
        case .doing: return MN.accent
        case .done: return .green
        case nil: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                iOSDocThumb(docId: doc.id)
                    .frame(height: 196)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(isNarratingThisDoc ? MN.accent : Color.black.opacity(0.08), lineWidth: isNarratingThisDoc ? 1.6 : 0.6))

                HStack(spacing: 4) {
                    if doc.pendingConflict != nil {
                        Button {
                            onOpenProgressHistory?()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                    .font(.system(size: 9, weight: .bold))
                                Text(L("进度冲突"))
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.orange))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    } else if !Paths.hasLocalPDF(doc.id) {
                        HStack(spacing: 3) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text(L("待下载"))
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(MN.accent.opacity(0.88)))
                        .foregroundStyle(.white)
                    }
                    Spacer()
                    Button {
                        store.cycleStatusTag(doc.id)
                    } label: {
                        let st = doc.statusTag
                        HStack(spacing: 3) {
                            Image(systemName: st?.icon ?? "tag")
                                .font(.system(size: 10, weight: .bold))
                            Text(st?.rawValue ?? "TAG")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(st != nil ? statusColor(st) : Color.black.opacity(0.55)))
                        .foregroundStyle(.white)
                    }
                }
                .padding(8)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            togglePodcastForDoc()
                        } label: {
                            Image(systemName: isNarratingThisDoc ? (narrator.state == .playing ? "waveform" : "pause.fill") : "headphones")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(isNarratingThisDoc ? MN.accent : Color.black.opacity(0.58)))
                                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
            }
            .onTapGesture { onTap() }

            Text(doc.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(minHeight: 34, alignment: .topLeading)
                .onTapGesture { onTap() }

            if !doc.customTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(doc.customTags, id: \.self) { ct in
                            Text("#" + ct)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(MN.accent.opacity(0.12)))
                                .foregroundStyle(MN.accent)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let total = doc.pageCount {
                        let cur = min(total, (doc.resolvedReadPage ?? 0) + 1)
                        Text("p.\(cur)/\(total)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("PDF")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(doc.progressPercent)%")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(statusColor(doc.statusTag))
                }
                ProgressView(value: max(0.03, doc.progressFraction))
                    .tint(statusColor(doc.statusTag))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
        .contextMenu {
            Button { onTap() } label: { Label(L("打开阅读"), systemImage: "book") }
            Button {
                togglePodcastForDoc()
            } label: {
                Label(isNarratingThisDoc ? (narrator.state == .playing ? L("暂停解读") : L("继续解读")) : L("AI 语音解读"), systemImage: isNarratingThisDoc ? "waveform" : "headphones")
            }
            if let onOpenProgressHistory {
                Button {
                    onOpenProgressHistory()
                } label: {
                    Label(L("多端阅读进度与恢复…"), systemImage: "clock.arrow.circlepath")
                }
            }
            Menu {
                Button {
                    _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: false)
                } label: {
                    Label(L("清理语音与视频缓存"), systemImage: "waveform.slash")
                }
                Button {
                    _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: true)
                } label: {
                    Label(L("清理语音、视频与双语缓存"), systemImage: "doc.badge.gearshape")
                }
                Button(role: .destructive) {
                    _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: true, includeBilingual: false)
                } label: {
                    Label(L("完全重置（含 AI 讲解稿）"), systemImage: "trash.slash")
                }
            } label: {
                Label(L("重置音频与视频空间"), systemImage: "externaldrive.badge.minus")
            }
            Divider()
            ForEach(DocStatusTag.allCases) { st in
                Button {
                    store.setStatusTag(doc.id, doc.statusTag == st ? nil : st)
                } label: {
                    Label(st.rawValue, systemImage: doc.statusTag == st ? "checkmark.circle.fill" : st.icon)
                }
            }
            Button { onAddCustomTag() } label: { Label(L("添加自定义标签…"), systemImage: "tag.fill") }
            if !store.lib.notebooks.isEmpty {
                Menu(L("加入笔记本")) {
                    ForEach(store.lib.notebooks) { nb in
                        let inside = nb.docIds.contains(doc.id)
                        Button {
                            if inside {
                                store.currentNotebookId = nb.id
                                store.removeDocFromNotebook(doc.id)
                            } else {
                                store.addDocToNotebook(doc.id, notebook: nb.id)
                            }
                        } label: {
                            Label(nb.name, systemImage: inside ? "checkmark.circle.fill" : "book.closed")
                        }
                    }
                }
            }
            if let nbId = activeNotebookId {
                Button {
                    store.currentNotebookId = nbId
                    store.removeDocFromNotebook(doc.id)
                } label: {
                    Label(L("从此笔记本移除"), systemImage: "folder.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.deleteDoc(doc.id)
            } label: {
                Label(L("删除文档"), systemImage: "trash")
            }
        }
    }
}

struct iOSDocThumb: View {
    let docId: UUID
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.gray.opacity(0.45))
            }
        }
        .task(id: docId) {
            guard image == nil else { return }
            if let loaded = await Self.loadOrRender(docId: docId) {
                image = loaded
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if image == nil, let retryLoaded = await Self.loadOrRender(docId: docId) {
                image = retryLoaded
            }
        }
    }

    private static func loadOrRender(docId: UUID) async -> UIImage? {
        let thumbFile = Paths.docDir(docId).appendingPathComponent("thumb.png")
        if let d = try? Data(contentsOf: thumbFile), let ui = UIImage(data: d) {
            return ui
        }
        let pdfURL = Paths.pdf(docId)
        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let doc = PDFDocument(url: pdfURL), let p0 = doc.safePage(0) else { return nil }
            if let png = PlatformPDF.thumbnailPNG(p0, size: CGSize(width: 280, height: 372)) {
                try? png.write(to: thumbFile, options: .atomic)
                return UIImage(data: png)
            }
            return nil
        }.value
    }
}

// MARK: - Full-Screen Bilingual PDF Reader & Study View

struct iOSDocumentStudyView: View {
    @ObservedObject var store: Store
    let docId: UUID
    let onClose: () -> Void
    var onSwitchDoc: ((UUID) -> Void)? = nil

    @ObservedObject private var rc = ReaderController.shared
    @ObservedObject private var narrator = Narrator.shared
    @ObservedObject private var themeCenter = iOSThemeCenter.shared
    @State private var viewMode: Int = 0 // 0 = PDF, 1 = Split, 2 = MindMap
    @State private var showCopilotSheet = false
    @State private var showOutlineSheet = false
    @State private var showFlashcardsSheet = false
    @State private var showVoiceSettingsSheet = false
    @State private var showProgressHistorySheet = false
    @State private var showPDFEditConfirmation: String?

    private var doc: Doc? { store.doc(docId) }
    private var session: DocSession? { store.session(docId) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topReaderControlBar

                if let conflict = doc?.pendingConflict {
                    iOSProgressConflictBanner(
                        conflict: conflict,
                        onKeepLocal: {
                            store.resolveProgressConflict(docId, useRemote: false)
                        },
                        onAcceptRemote: {
                            store.resolveProgressConflict(docId, useRemote: true)
                            rc.goToPage(conflict.remotePage)
                        },
                        onOpenDetails: {
                            showProgressHistorySheet = true
                        },
                        onDismiss: {
                            store.dismissProgressConflict(docId)
                        }
                    )
                }

                ZStack(alignment: .bottom) {
                    Group {
                        if session == nil && viewMode != 2 {
                            iOSPDFDownloadRecoveryView(store: store, docId: docId) {
                                rc.bind(docId: docId)
                            }
                        } else if viewMode == 0 {
                            iOSThemedPDFView(store: store, rc: rc, session: session, theme: themeCenter.theme)
                        } else if viewMode == 1 {
                            GeometryReader { geo in
                                if geo.size.width > geo.size.height {
                                    HStack(spacing: 0) {
                                        iOSThemedPDFView(store: store, rc: rc, session: session, theme: themeCenter.theme)
                                            .frame(width: geo.size.width * 0.56)
                                        Divider()
                                        MindMapView(store: store)
                                    }
                                } else {
                                    VStack(spacing: 0) {
                                        iOSThemedPDFView(store: store, rc: rc, session: session, theme: themeCenter.theme)
                                            .frame(height: geo.size.height * 0.58)
                                        Divider()
                                        MindMapView(store: store)
                                    }
                                }
                            }
                        } else {
                            MindMapView(store: store)
                        }
                    }

                    VStack(spacing: 10) {
                        if !rc.selectionText.isEmpty {
                            iOSSelectionExcerptBar(
                                rc: rc,
                                onAskAI: {
                                    showCopilotSheet = true
                                }
                            )
                            .padding(.horizontal, 12)
                        }

                        if narrator.state != .idle && narrator.docId == docId {
                            iOSNarratorBar(
                                narrator: narrator,
                                rc: rc,
                                onOpenVoiceSettings: { showVoiceSettingsSheet = true }
                            )
                            .padding(.horizontal, 12)
                        } else if narrator.state != .idle, let nDocId = narrator.docId, nDocId != docId, store.doc(nDocId) != nil {
                            iOSPodcastMiniPlayerBar(
                                store: store,
                                narrator: narrator,
                                onOpenNarratedDoc: {
                                    onSwitchDoc?(nDocId)
                                }
                            )
                            .padding(.horizontal, 12)
                        }

                        bottomReaderControlBar
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                rc.bind(docId: docId)
                DocWindows.shared.activeDocId = docId
                if narrator.state != .idle && narrator.docId == docId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if rc.currentPageIndex != narrator.page {
                            rc.goToPage(narrator.page)
                        }
                        if narrator.segIndex < narrator.segments.count {
                            rc.highlightNarration(page: narrator.page, quote: narrator.segments[narrator.segIndex].focus)
                        }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--narrate") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if narrator.state == .idle {
                            toggleNarration()
                        }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--voice-settings") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showVoiceSettingsSheet = true
                    }
                }
            }
            .sheet(isPresented: $showCopilotSheet) {
                iOSCopilotSheet(store: store, rc: rc, docId: docId)
                    .preferredColorScheme(themeCenter.colorScheme)
            }
            .sheet(isPresented: $showOutlineSheet) {
                iOSOutlineAndCardsSheet(store: store, rc: rc, docId: docId)
                    .preferredColorScheme(themeCenter.colorScheme)
            }
            .sheet(isPresented: $showFlashcardsSheet) {
                NavigationStack {
                    iOSMobileFlashcardsContent(store: store, rc: rc, docId: docId)
                        .navigationTitle(L("AI 学习闪卡"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L("完成")) { showFlashcardsSheet = false }
                            }
                        }
                }
                .preferredColorScheme(themeCenter.colorScheme)
            }
            .sheet(isPresented: $showVoiceSettingsSheet) {
                iOSVoiceSettingsSheet()
                    .preferredColorScheme(themeCenter.colorScheme)
            }
            .sheet(isPresented: $showProgressHistorySheet) {
                iOSDocProgressHistorySheet(store: store, docId: docId, onJumpToPage: { p in
                    rc.goToPage(p)
                })
                .preferredColorScheme(themeCenter.colorScheme)
            }
        }
    }

    private var topReaderControlBar: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MN.ink.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("书架"))

            Text(doc?.title ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MN.ink.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Button {
                    rc.setVariant(rc.variant == .bilingual ? .original : .bilingual)
                } label: {
                    let isBi = rc.variant == .bilingual
                    Image(systemName: "translate")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isBi ? MN.accent : MN.ink.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isBi ? MN.accent.opacity(0.15) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("双语"))

                Button {
                    toggleNarration()
                } label: {
                    let isPlaying = narrator.state != .idle && narrator.docId == docId
                    Image(systemName: isPlaying ? "waveform" : "headphones")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isPlaying ? MN.accent : MN.ink.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isPlaying ? MN.accent.opacity(0.15) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("AI 解读"))

                Button {
                    showCopilotSheet = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(MN.ink.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("AI 阅读助手"))

                Menu {
                    Section(L("界面主题")) {
                        ForEach(AppTheme.allCases) { t in
                            Button {
                                themeCenter.set(t)
                            } label: {
                                if themeCenter.theme == t {
                                    Label(t.name, systemImage: "checkmark")
                                } else {
                                    Text(t.name)
                                }
                            }
                        }
                    }
                    Section(L("视图切换")) {
                        Button { viewMode = 0 } label: { Label(L("仅看 PDF"), systemImage: viewMode == 0 ? "checkmark" : "doc.richtext") }
                        Button { viewMode = 1 } label: { Label(L("PDF + 脑图分屏"), systemImage: viewMode == 1 ? "checkmark" : "rectangle.split.2x1") }
                        Button { viewMode = 2 } label: { Label(L("仅看脑图"), systemImage: viewMode == 2 ? "checkmark" : "point.3.connected.trianglepath.dotted") }
                    }
                    Section(L("阅读状态标签")) {
                        ForEach(DocStatusTag.allCases) { st in
                            Button {
                                store.setStatusTag(docId, doc?.statusTag == st ? nil : st)
                            } label: {
                                Label(st.rawValue, systemImage: doc?.statusTag == st ? "checkmark.circle.fill" : st.icon)
                            }
                        }
                    }
                    if rc.variant == .bilingual, let ses = session {
                        Section(L("双语对照")) {
                            Button {
                                ses.translateWholeDocument(from: rc.currentPageIndex)
                            } label: {
                                Label(L("全文翻译"), systemImage: "translate")
                            }
                            Button {
                                Task { await ses.retranslate(rc.currentPageIndex) }
                            } label: {
                                Label(L("重新翻译本页"), systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    if let ses = session {
                        Section(L("PDF 页面编辑")) {
                            Button {
                                let box = ses.original.safePage(rc.currentPageIndex)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 600, height: 800)
                                _ = PDFEditor.truncateFromHereToEnd(session: ses, pageIndex: rc.currentPageIndex, origY: box.midY)
                            } label: {
                                Label(L("从本页中部截断后续内容"), systemImage: "scissors")
                            }
                            if ses.pageCount > 1 {
                                Button(role: .destructive) {
                                    _ = PDFEditor.deletePage(session: ses, pageIndex: rc.currentPageIndex)
                                } label: {
                                    Label(L("删除当前页"), systemImage: "trash")
                                }
                                if rc.currentPageIndex + 1 < ses.pageCount {
                                    Button(role: .destructive) {
                                        _ = PDFEditor.deletePagesAfter(session: ses, pageIndex: rc.currentPageIndex)
                                    } label: {
                                        Label(L("删除本页之后的全部页面"), systemImage: "arrow.down.to.line")
                                    }
                                }
                            }
                            if PDFEditor.hasBackup(docId) {
                                Button {
                                    _ = PDFEditor.restoreOriginal(session: ses)
                                } label: {
                                    Label(L("恢复未裁剪的原版 PDF"), systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                    Section(L("学习工具")) {
                        Button { showOutlineSheet = true } label: { Label(L("目录与摘录卡片"), systemImage: "list.bullet.indent") }
                        Button { showFlashcardsSheet = true } label: { Label(L("AI 学习闪卡"), systemImage: "rectangle.on.rectangle.angled") }
                        Button { showProgressHistorySheet = true } label: { Label(L("多端阅读进度与恢复…"), systemImage: "clock.arrow.circlepath") }
                        Menu {
                            Button {
                                _ = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: false, includeBilingual: false)
                            } label: {
                                Label(L("清理语音与视频缓存"), systemImage: "waveform.slash")
                            }
                            Button {
                                _ = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: false, includeBilingual: true)
                            } label: {
                                Label(L("清理语音、视频与双语缓存"), systemImage: "doc.badge.gearshape")
                            }
                            Button(role: .destructive) {
                                _ = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: true, includeBilingual: false)
                            } label: {
                                Label(L("完全重置（含 AI 讲解稿）"), systemImage: "trash.slash")
                            }
                        } label: {
                            Label(L("重置音频与视频空间"), systemImage: "externaldrive.badge.minus")
                        }
                    }
                    if let ses = session {
                        Section(L("AI 语音解读")) {
                            Button {
                                let curPage = rc.syncCurrentPageFromView()
                                narrator.start(docId: docId, doc: ses.document(rc.variant), title: ses.doc.title, from: curPage, resume: false)
                            } label: {
                                Label(LF("从当前页开始讲 (p.%d)", rc.currentPageIndex + 1), systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            if let saved = Narrator.savedProgress(docId), (saved.page > 0 || saved.seg > 0) {
                                Button {
                                    narrator.start(docId: docId, doc: ses.document(rc.variant), title: ses.doc.title, from: saved.page, resume: true)
                                } label: {
                                    Label(LF("继续上次讲解 (p.%d · 第 %d 段)", saved.page + 1, saved.seg + 1), systemImage: "play.circle")
                                }
                            }
                            Button {
                                let curPage = rc.syncCurrentPageFromView()
                                NarrationExporter.shared.start(prepareOnly: true, forDocId: docId, fromPage: curPage)
                            } label: {
                                Label(L("准备全部讲解"), systemImage: "tray.and.arrow.down")
                            }
                            .disabled(NarrationExporter.shared.running)
                            Menu {
                                Section(LF("音色 (%@)", L(narrator.effectiveProvider.shortTitle))) {
                                    ForEach(narrator.voiceOptions) { o in
                                        Button {
                                            narrator.selectVoice(o.id)
                                        } label: {
                                            if narrator.currentVoiceID == o.id {
                                                Label(L(o.label), systemImage: "checkmark")
                                            } else {
                                                Text(L(o.label))
                                            }
                                        }
                                    }
                                }
                                Menu {
                                    ForEach(TTSProvider.allCases) { p in
                                        Button {
                                            narrator.selectProvider(p)
                                        } label: {
                                            if narrator.provider == p && !narrator.fallbackToSystem {
                                                Label(L(p.title), systemImage: "checkmark")
                                            } else {
                                                Text(L(p.title))
                                            }
                                        }
                                    }
                                } label: {
                                    Label(L("音色来源"), systemImage: "waveform.badge.magnifyingglass")
                                }
                                Menu {
                                    ForEach(NarrationStyle.allCases) { st in
                                        Button {
                                            Settings.narrationStyle = st
                                            CloudSync.shared.recordSettingsChange()
                                        } label: {
                                            if Settings.narrationStyle == st {
                                                Label(L(st.title), systemImage: "checkmark")
                                            } else {
                                                Text(L(st.title) + " — " + L(st.subtitle))
                                            }
                                        }
                                    }
                                } label: {
                                    Label(L("讲解风格"), systemImage: "theatermasks")
                                }
                                Divider()
                                Button {
                                    showVoiceSettingsSheet = true
                                } label: {
                                    Label(L("语音与音色设置…"), systemImage: "slider.horizontal.3")
                                }
                            } label: {
                                Label(
                                    LF("音色与来源：%@ · %@", L(narrator.effectiveProvider.shortTitle), narrator.currentVoiceName),
                                    systemImage: narrator.effectiveProvider == .system ? "person.wave.2" : "cloud"
                                )
                            }
                            Button {
                                showVoiceSettingsSheet = true
                            } label: {
                                Label(L("语音与音色设置…"), systemImage: "slider.horizontal.3")
                            }
                            if narrator.state != .idle && narrator.docId == docId {
                                Button(role: .destructive) {
                                    narrator.stop()
                                    rc.clearNarrationHighlight()
                                } label: {
                                    Label(L("退出 AI 解读"), systemImage: "stop.circle")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(MN.ink.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(MN.status)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func toggleNarration() {
        guard let ses = session else { return }
        let curPage = rc.syncCurrentPageFromView()
        if narrator.state != .idle && narrator.docId == docId {
            if curPage != narrator.page {
                narrator.narrateFromReaderPage()
            } else {
                narrator.togglePause()
            }
        } else {
            narrator.start(docId: docId, doc: ses.document(rc.variant), title: ses.doc.title, from: curPage)
        }
    }

    private var bottomReaderControlBar: some View {
        HStack(spacing: 12) {
            Button {
                rc.goToPage(rc.currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
            }
            .disabled(rc.currentPageIndex <= 0)

            Button {
                showProgressHistorySheet = true
            } label: {
                HStack(spacing: 4) {
                    Text("p.\(rc.currentPageIndex + 1) / \(max(1, rc.pageCount))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MN.ink)
                    if doc?.pendingConflict != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MN.statusText)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                rc.goToPage(rc.currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .disabled(rc.currentPageIndex + 1 >= rc.pageCount)

            if rc.variant == .bilingual, let ses = session {
                Divider().frame(height: 14)
                if !ses.running.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                Text(ses.progressText.isEmpty ? L("双语") : ses.progressText)
                    .font(.caption2)
                    .foregroundStyle(MN.statusText)
                    .lineLimit(1)
            }

            Spacer()

            Picker("", selection: $viewMode) {
                Image(systemName: "doc.richtext").tag(0)
                Image(systemName: "rectangle.split.2x1").tag(1)
                Image(systemName: "point.3.connected.trianglepath.dotted").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MN.status)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct iOSPDFDownloadRecoveryView: View {
    @ObservedObject var store: Store
    let docId: UUID
    let onLoaded: () -> Void
    @State private var isDownloading = true

    var body: some View {
        VStack(spacing: 14) {
            if isDownloading {
                ProgressView()
                    .controlSize(.large)
                    .tint(MN.accent)
            } else {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 38))
                    .foregroundStyle(MN.accent)
            }
            Text(L("正在从 iCloud 下载 PDF 文档…"))
                .font(.headline)
            Text(L("该文档的元数据已同步，正在拉取完整 PDF 文件，请稍候或点击重试。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                triggerDownload()
            } label: {
                Label(L("立即拉取 PDF"), systemImage: "arrow.clockwise.icloud")
            }
            .buttonStyle(.borderedProminent)
            .tint(MN.accent)
            .disabled(isDownloading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MN.paper)
        .task(id: docId) {
            await performDownload()
        }
    }

    private func triggerDownload() {
        Task { await performDownload() }
    }

    private func performDownload() async {
        isDownloading = true
        let ok = await CloudSync.shared.ensurePDFDownloaded(docId)
        isDownloading = false
        if ok {
            store.objectWillChange.send()
            onLoaded()
        }
    }
}

struct iOSProgressConflictBanner: View {
    let conflict: ProgressConflict
    let onKeepLocal: () -> Void
    let onAcceptRemote: () -> Void
    let onOpenDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("检测到多设备阅读进度冲突"))
                        .font(.caption.weight(.bold))
                    Text(LF("本机 (%@) 位于第 %d 页，另一设备 (%@) 位于第 %d 页", conflict.localDeviceName, conflict.localPage + 1, conflict.remoteDeviceName, conflict.remotePage + 1))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button(action: onKeepLocal) {
                    Text(LF("保留本机 (p.%d)", conflict.localPage + 1))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button(action: onAcceptRemote) {
                    Text(LF("采用 %@ (p.%d)", conflict.remoteDeviceName, conflict.remotePage + 1))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(MN.accent))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onOpenDetails) {
                    Text(L("多端阅读进度与恢复"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MN.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct iOSDocProgressHistorySheet: View {
    @ObservedObject var store: Store
    let docId: UUID
    let onJumpToPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mediaUsage: StorageManager.DocMediaUsage?
    @State private var resetToast: String = ""

    private var doc: Doc? { store.doc(docId) }

    var body: some View {
        NavigationStack {
            List {
                if let conflict = doc?.pendingConflict {
                    Section(L("检测到多设备阅读进度冲突")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LF("本机 (%@) 位于第 %d 页，另一设备 (%@) 位于第 %d 页", conflict.localDeviceName, conflict.localPage + 1, conflict.remoteDeviceName, conflict.remotePage + 1))
                                .font(.footnote)
                            HStack(spacing: 10) {
                                Button {
                                    store.resolveProgressConflict(docId, useRemote: false)
                                    onJumpToPage(conflict.localPage)
                                    dismiss()
                                } label: {
                                    Text(LF("保留本机 (p.%d)", conflict.localPage + 1))
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    store.resolveProgressConflict(docId, useRemote: true)
                                    onJumpToPage(conflict.remotePage)
                                    dismiss()
                                } label: {
                                    Text(LF("采用 %@ (p.%d)", conflict.remoteDeviceName, conflict.remotePage + 1))
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(MN.accent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(L("各设备阅读与讲解进度")) {
                    let history = doc?.deviceProgressHistory ?? []
                    if history.isEmpty {
                        Text(L("暂无多设备同步记录"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history) { snap in
                            let isThisDevice = snap.deviceId == DeviceIdentity.currentDeviceId
                            HStack(spacing: 10) {
                                Image(systemName: snap.deviceName.lowercased().contains("mac") ? "laptopcomputer" : "iphone")
                                    .foregroundStyle(isThisDevice ? MN.accent : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(snap.deviceName)
                                            .font(.subheadline.weight(.semibold))
                                        if isThisDevice {
                                            Text(L("本机"))
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Capsule().fill(MN.accent.opacity(0.14)))
                                                .foregroundStyle(MN.accent)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(LF("阅读至 p.%d", snap.readPage + 1))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.primary)
                                        if let np = snap.narrationPage, (np > 0 || (snap.narrationSeg ?? 0) > 0) {
                                            Text("· " + LF("讲解 p.%d · 第 %d 段", np + 1, (snap.narrationSeg ?? 0) + 1))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(MN.accent)
                                        }
                                    }
                                    Text(snap.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.restoreProgressSnapshot(docId, page: snap.readPage, narrationPage: snap.narrationPage, narrationSeg: snap.narrationSeg)
                                    onJumpToPage(snap.readPage)
                                    dismiss()
                                } label: {
                                    Text(L("恢复到此进度"))
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(MN.accent)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section(L("每日阅读足迹")) {
                    let log = (doc?.dailyReadingLog ?? [:]).sorted { $0.key > $1.key }
                    if log.isEmpty {
                        Text(L("暂无每日阅读记录"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(log, id: \.key) { day, pageIdx in
                            HStack {
                                Label(day, systemImage: "calendar")
                                    .font(.subheadline.monospacedDigit())
                                Spacer()
                                Text(LF("阅读至 p.%d", pageIdx + 1))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Button {
                                    store.restoreProgressSnapshot(docId, page: pageIdx)
                                    onJumpToPage(pageIdx)
                                    dismiss()
                                } label: {
                                    Text(LF("跳至 p.%d", pageIdx + 1))
                                        .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section(L("本篇音频与视频占用")) {
                    if let u = mediaUsage {
                        Text(LF("语音 %@ (%d 段) · 视频 %@ (%d 个) · 讲稿 %@", StorageManager.format(u.audioBytes), u.audioCount, StorageManager.format(u.videoBytes), u.videoCount, StorageManager.format(u.scriptBytes)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !resetToast.isEmpty {
                        Text(resetToast)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Button {
                        let freed = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: false, includeBilingual: false)
                        resetToast = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                        refreshMediaUsage()
                    } label: {
                        Label(L("清理语音与视频缓存"), systemImage: "waveform.slash")
                    }
                    Button {
                        let freed = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: false, includeBilingual: true)
                        resetToast = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                        refreshMediaUsage()
                    } label: {
                        Label(L("清理语音、视频与双语缓存"), systemImage: "doc.badge.gearshape")
                    }
                    Button(role: .destructive) {
                        let freed = StorageManager.resetDocMedia(docId, title: doc?.title, includeScripts: true, includeBilingual: false)
                        resetToast = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                        refreshMediaUsage()
                    } label: {
                        Label(L("完全重置（含 AI 讲解稿）"), systemImage: "trash.slash")
                    }
                }
            }
            .navigationTitle(L("多端阅读进度与恢复"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
            .onAppear {
                refreshMediaUsage()
            }
        }
    }

    private func refreshMediaUsage() {
        mediaUsage = StorageManager.docMediaUsage(docId, title: doc?.title)
    }
}

// MARK: - PDFKit UIViewRepresentable & Floating Reader Bars

struct iOSThemedPDFView: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let session: DocSession?
    let theme: AppTheme

    var body: some View {
        ZStack {
            iOSPDFContainerView(store: store, rc: rc, session: session, theme: theme)
            if theme == .sepia {
                Color(red: 0.97, green: 0.91, blue: 0.80)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            } else if theme == .dark {
                Color(white: 0.92)
                    .blendMode(.difference)
                    .allowsHitTesting(false)
            }
        }
    }
}

final class iOSPDFHostView: UIView {
    weak var rc: ReaderController?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 10 && bounds.height > 10 {
            rc?.applyPendingInitialPageIfNeeded()
        }
    }
}

struct iOSPDFContainerView: UIViewRepresentable {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let session: DocSession?
    let theme: AppTheme

    private var preBlendBackgroundColor: UIColor {
        switch theme {
        case .light:
            return MN.paperNS
        case .sepia:
            return UIColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1)
        case .dark:
            return UIColor(calibratedWhite: 0.98, alpha: 1)
        }
    }

    func makeUIView(context: Context) -> iOSPDFHostView {
        let container = iOSPDFHostView()
        container.rc = rc
        let bg = preBlendBackgroundColor
        container.backgroundColor = bg
        rc.view.backgroundColor = bg
        for sub in rc.view.subviews { sub.backgroundColor = bg }
        rc.view.frame = container.bounds
        rc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(rc.view)
        return container
    }

    func updateUIView(_ uiView: iOSPDFHostView, context: Context) {
        uiView.rc = rc
        let bg = preBlendBackgroundColor
        uiView.backgroundColor = bg
        rc.view.backgroundColor = bg
        for sub in rc.view.subviews { sub.backgroundColor = bg }
        guard let session else { return }
        if rc.docId != session.doc.id {
            rc.bind(docId: session.doc.id)
        } else {
            rc.applyPendingInitialPageIfNeeded()
        }
    }
}

struct iOSSelectionExcerptBar: View {
    @ObservedObject var rc: ReaderController
    let onAskAI: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<min(6, highlightColors.count), id: \.self) { i in
                Button {
                    _ = rc.excerptSelection(color: i)
                } label: {
                    Circle()
                        .fill(Color(uiColor: highlightColors[i]))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1))
                }
            }
            Divider().frame(height: 18)
            Button {
                PlatformClipboard.copy(rc.selectionText)
                rc.view.clearSelection()
                rc.selectionText = ""
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.subheadline)
            }
            Button {
                onAskAI()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(L("问 AI"))
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(MN.accent))
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(MN.panel).shadow(color: .black.opacity(0.18), radius: 8, y: 3))
    }
}

struct iOSNarratorBar: View {
    @ObservedObject var narrator: Narrator
    @ObservedObject var rc: ReaderController
    var onOpenVoiceSettings: (() -> Void)? = nil
    @ObservedObject private var ex = NarrationExporter.shared
    @ObservedObject private var themeCenter = iOSThemeCenter.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var styleTick = 0
    @State private var confirmPrepare = false
    @State private var prepareEstimate = ""

    private var currentSubtitle: String {
        if narrator.listening {
            return narrator.heard.isEmpty ? L("正在聆听你的问题…") : narrator.heard
        }
        if narrator.answering {
            return L("AI 讲解员正在思考并组织回答…")
        }
        if let qa = narrator.lastQA {
            return "💬 \(qa.a)"
        }
        if narrator.segIndex < narrator.segments.count {
            return narrator.segments[narrator.segIndex].text
        }
        if narrator.state == .preparing {
            return L("正在阅读本页并组织讲解…")
        }
        return L("AI 语音解读中…")
    }

    private var cardSurfaceColor: Color {
        switch themeCenter.theme {
        case .dark:
            return Color(red: 0.13, green: 0.15, blue: 0.20)
        case .sepia:
            return Color(red: 0.95, green: 0.90, blue: 0.80)
        case .light:
            return Color(red: 0.96, green: 0.975, blue: 1.0)
        }
    }

    private var subtitleBoxColor: Color {
        switch themeCenter.theme {
        case .dark:
            return Color.white.opacity(0.06)
        case .sepia:
            return Color(red: 0.985, green: 0.96, blue: 0.90)
        case .light:
            return Color.white
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ex.phase != .idle {
                HStack(spacing: 8) {
                    Image(systemName: ex.phase == .failed ? "exclamationmark.triangle.fill" : (ex.phase == .done ? "checkmark.circle.fill" : "tray.and.arrow.down.fill"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ex.phase == .failed ? .red : MN.accent)
                    Text(ex.statusText)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if ex.running, ex.total > 0 {
                        ProgressView(value: Double(ex.done), total: Double(ex.total))
                            .tint(MN.accent)
                            .frame(width: 64)
                    } else if ex.running {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 4)
                    if ex.running {
                        Button(L("取消")) { ex.cancel() }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    } else {
                        Button { ex.phase = .idle } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(MN.accent.opacity(0.1)))
            }

            // Row 1: Header with AI badge, page/segment counter, buffered count, "From here" action, Prepare All, and Close button
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(MN.accent))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("p.\(narrator.page + 1) · \(narrator.segIndex + 1)/\(max(1, narrator.segments.count))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let eta = narrator.remainingSeconds().map { " · " + Narrator.formatRemainingShort($0) } ?? ""
                            Text(LF("已缓冲 %d 段", narrator.buffered) + eta)
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    prepareEstimate = NarrationExporter.estimateText(narrator.preparePlan())
                    confirmPrepare = true
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MN.accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(MN.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(ex.running)
                .accessibilityLabel(L("准备全部讲解"))
                .confirmationDialog(LF("为全部 %d 页生成讲解和语音？", narrator.pageCount), isPresented: $confirmPrepare) {
                    Button(L("开始准备")) { ex.start(prepareOnly: true) }
                    Button(L("取消"), role: .cancel) {}
                } message: {
                    Text(L("会从当前页开始，在后台逐页调用模型写讲稿，再合成全部语音；已生成的部分会跳过。页数多时需要较长时间并产生相应的模型费用，可以随时取消。") + "\n\n" + prepareEstimate)
                }

                Button {
                    _ = rc.syncCurrentPageFromView()
                    if rc.currentPageIndex != narrator.page {
                        narrator.narrateFromReaderPage()
                    } else {
                        narrator.restartFromCurrentPage()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.caption2.weight(.bold))
                        Text(rc.currentPageIndex != narrator.page
                             ? LF("从第 %d 页讲", rc.currentPageIndex + 1)
                             : L("从本页讲"))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MN.accent.opacity(0.14)))
                    .overlay(Capsule().stroke(MN.accent.opacity(0.3), lineWidth: 0.8))
                    .foregroundStyle(MN.accent)
                }
                .buttonStyle(.plain)

                Button {
                    narrator.stop()
                    rc.clearNarrationHighlight()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if narrator.fallbackToSystem {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(L("网关 TTS 不可用，已改用系统语音"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        narrator.selectProvider(narrator.provider)
                    } label: {
                        Text(L("重试"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MN.accent)
                    }
                    .buttonStyle(.plain)
                    if let onOpenVoiceSettings {
                        Button {
                            onOpenVoiceSettings()
                        } label: {
                            Text(L("设置…"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let r = narrator.resumedFrom, r.page == narrator.page {
                Button {
                    narrator.restartFromCurrentPage()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(LF("已从第 %d 页第 %d 段继续 · 点击从本页开头重新讲", r.page + 1, r.seg + 1))
                            .lineLimit(1)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MN.accent)
                }
                .buttonStyle(.plain)
            }

            // Row 2: Elevated inner subtitle box for clear reading hierarchy
            VStack(alignment: .leading, spacing: 4) {
                if narrator.state == .preparing && !narrator.segments.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L("正在生成语音…"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MN.accent)
                    }
                }

                Text(currentSubtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let err = narrator.error, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(subtitleBoxColor)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MN.accent.opacity(0.16), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.18), value: currentSubtitle)

            // Row 3: Spacious Transport & Voice Controls
            HStack(spacing: 10) {
                HStack(spacing: 14) {
                    Button {
                        narrator.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        narrator.togglePause()
                    } label: {
                        if narrator.state == .preparing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(MN.accent.opacity(0.14)))
                        } else {
                            Image(systemName: narrator.state == .playing ? "pause.fill" : "play.fill")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(MN.accent).shadow(color: MN.accent.opacity(0.35), radius: 5, y: 2))
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        narrator.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                // Compact, reasonably hidden Voice & Source Menu pill
                let _ = styleTick
                Menu {
                    Section(LF("音色 (%@)", L(narrator.effectiveProvider.shortTitle))) {
                        ForEach(narrator.voiceOptions) { o in
                            Button {
                                narrator.selectVoice(o.id)
                            } label: {
                                if narrator.currentVoiceID == o.id {
                                    Label(L(o.label), systemImage: "checkmark")
                                } else {
                                    Text(L(o.label))
                                }
                            }
                        }
                    }
                    Menu {
                        ForEach(TTSProvider.allCases) { p in
                            Button {
                                narrator.selectProvider(p)
                            } label: {
                                if narrator.provider == p && !narrator.fallbackToSystem {
                                    Label(L(p.title), systemImage: "checkmark")
                                } else {
                                    Text(L(p.title))
                                }
                            }
                        }
                    } label: {
                        Label(L("音色来源"), systemImage: "waveform.badge.magnifyingglass")
                    }
                    Menu {
                        ForEach(NarrationStyle.allCases) { st in
                            Button {
                                Settings.narrationStyle = st
                                styleTick += 1
                                CloudSync.shared.recordSettingsChange()
                            } label: {
                                if Settings.narrationStyle == st {
                                    Label(L(st.title), systemImage: "checkmark")
                                } else {
                                    Text(L(st.title) + " — " + L(st.subtitle))
                                }
                            }
                        }
                    } label: {
                        Label(L("讲解风格"), systemImage: "theatermasks")
                    }
                    if let onOpenVoiceSettings {
                        Divider()
                        Button {
                            onOpenVoiceSettings()
                        } label: {
                            Label(L("语音与音色设置…"), systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: narrator.effectiveProvider == .system ? "person.wave.2" : "cloud")
                            .font(.caption2.weight(.bold))
                        Text(narrator.currentVoiceName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 68)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(MN.accent.opacity(0.14)))
                    .foregroundStyle(MN.accent)
                }
                .accessibilityLabel(L("音色"))

                Menu {
                    ForEach([Float(0.75), 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { spd in
                        Button {
                            narrator.rate = spd
                        } label: {
                            HStack {
                                Text(String(format: "%.2gx", spd))
                                if abs(narrator.rate - spd) < 0.05 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(String(format: "%.2gx", narrator.rate))
                        .font(.caption.monospacedDigit().weight(.bold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(MN.accent.opacity(0.14)))
                        .foregroundStyle(MN.accent)
                }

                Button {
                    if narrator.listening {
                        narrator.endQuestion()
                    } else {
                        narrator.beginQuestion()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: narrator.listening ? "mic.fill" : "mic")
                            .font(.caption.weight(.bold))
                        Text(narrator.listening ? L("松开发送") : L("提问"))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(narrator.listening ? .white : MN.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(narrator.listening ? Color.red : MN.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardSurfaceColor)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 18, y: 6)
                .shadow(color: MN.accent.opacity(0.12), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MN.accent.opacity(colorScheme == .dark ? 0.45 : 0.35), lineWidth: 1.5)
        )
    }
}

struct iOSPodcastMiniPlayerBar: View {
    @ObservedObject var store: Store
    @ObservedObject var narrator: Narrator
    let onOpenNarratedDoc: () -> Void
    @ObservedObject private var themeCenter = iOSThemeCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    private var currentSubtitle: String {
        if narrator.segIndex < narrator.segments.count {
            return narrator.segments[narrator.segIndex].text
        }
        if narrator.state == .preparing {
            return L("正在阅读本页并组织讲解…")
        }
        return L("AI 语音解读中…")
    }

    private var surfaceColor: Color {
        switch themeCenter.theme {
        case .dark:
            return Color(red: 0.13, green: 0.15, blue: 0.20)
        case .sepia:
            return Color(red: 0.95, green: 0.90, blue: 0.80)
        case .light:
            return Color(red: 0.96, green: 0.975, blue: 1.0)
        }
    }

    private var thumbImage: UIImage? {
        guard let id = narrator.docId else { return nil }
        let u = Paths.docDir(id).appendingPathComponent("thumb.png")
        if let d = try? Data(contentsOf: u), let img = UIImage(data: d) {
            return img
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenNarratedDoc) {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        if let img = thumbImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 38, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(MN.accent.opacity(0.16))
                                .frame(width: 38, height: 48)
                                .overlay(
                                    Image(systemName: "waveform")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(MN.accent)
                                )
                        }

                        Circle()
                            .fill(MN.accent)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Image(systemName: narrator.state == .playing ? "waveform" : "headphones")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 3, y: 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(narrator.narratedTitle.isEmpty ? (store.doc(narrator.docId ?? UUID())?.title ?? "") : narrator.narratedTitle)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text("p.\(narrator.page + 1)/\(max(1, narrator.pageCount))")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(MN.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(MN.accent.opacity(0.14)))
                        }

                        Text(currentSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button {
                    narrator.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button {
                    narrator.togglePause()
                } label: {
                    Group {
                        if narrator.state == .preparing {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: narrator.state == .playing ? "pause.fill" : "play.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(MN.accent))
                }
                .buttonStyle(.plain)

                Button {
                    narrator.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button {
                    narrator.stop()
                    ReaderController.shared.clearNarrationHighlight()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surfaceColor)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MN.accent.opacity(colorScheme == .dark ? 0.45 : 0.35), lineWidth: 1.2)
        )
    }
}

struct iOSCopilotSheet: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let docId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var openFlag = true

    var body: some View {
        NavigationStack {
            CopilotPanel(store: store, rc: rc, open: $openFlag)
                .navigationTitle(L("AI 阅读助手"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("完成")) { dismiss() }
                    }
                }
                .onChange(of: openFlag) { _, v in
                    if !v { dismiss() }
                }
        }
    }
}

struct iOSOutlineAndCardsSheet: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let docId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private var docCards: [Card] {
        store.lib.cards.filter { $0.docId == docId }.sorted { $0.page < $1.page }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L("摘录卡片") + " (\(docCards.count))").tag(0)
                    Text(L("目录")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(12)

                if tab == 0 {
                    if docCards.isEmpty {
                        ContentUnavailableView(
                            L("暂无摘录卡片"),
                            systemImage: "highlighter",
                            description: Text(L("在 PDF 页面上长按选中文本，即可一键高亮摘录并自动翻译。"))
                        )
                    } else {
                        List {
                            ForEach(docCards) { card in
                                Button {
                                    rc.jump(to: card)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Circle()
                                                .fill(Color(uiColor: highlightColors[card.color % highlightColors.count]))
                                                .frame(width: 10, height: 10)
                                            Text("p.\(card.page + 1)")
                                                .font(.caption.monospacedDigit().weight(.bold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        Text(card.text)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                        if let tr = card.translation, !tr.isEmpty {
                                            Text(tr)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        store.deleteCard(card.id)
                                    } label: {
                                        Label(L("删除"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ScrollView {
                        TOCList(rc: rc, query: "")
                    }
                }
            }
            .background(MN.shelf)
            .navigationTitle(L("目录与卡片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("关闭")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Tab 2: Mind Map Tab View

struct iOSMindMapTabView: View {
    @ObservedObject var store: Store
    let onJumpToDoc: (UUID) -> Void

    @State private var showNewNotebookAlert = false
    @State private var newNotebookName = ""

    var body: some View {
        NavigationStack {
            MindMapView(store: store)
                .navigationTitle(store.currentNotebook?.name ?? L("脑图"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(store.lib.notebooks) { nb in
                                Button {
                                    store.currentNotebookId = nb.id
                                    store.save()
                                } label: {
                                    Label(nb.name, systemImage: store.currentNotebookId == nb.id ? "checkmark" : "book.closed")
                                }
                            }
                            Divider()
                            Button {
                                newNotebookName = ""
                                showNewNotebookAlert = true
                            } label: {
                                Label(L("新建笔记本…"), systemImage: "plus")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "book.closed")
                                Text(L("笔记本"))
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            store.addChild(to: store.selectedNodeId ?? store.currentNotebook?.root.id)
                        } label: {
                            Image(systemName: "plus.rectangle.on.rectangle")
                        }
                        if let sel = store.selectedNodeId, let nb = store.currentNotebook, sel != nb.root.id {
                            Button(role: .destructive) {
                                store.deleteNode(sel)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .alert(L("新建笔记本"), isPresented: $showNewNotebookAlert) {
                    TextField(L("笔记本名称"), text: $newNotebookName)
                    Button(L("取消"), role: .cancel) {}
                    Button(L("创建")) {
                        let clean = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.newNotebook(name: clean.isEmpty ? L("新笔记本") : clean)
                    }
                }
        }
    }
}

// MARK: - Tab 3: Flashcards Tab View & Mobile Study Session

struct iOSFlashcardsTabView: View {
    @ObservedObject var store: Store
    @ObservedObject private var rc = ReaderController.shared
    @ObservedObject private var fs = FlashStore.shared

    private var activeDocId: UUID? {
        if let id = rc.docId, store.doc(id) != nil { return id }
        if let id = store.currentDocId, store.doc(id) != nil { return id }
        return store.lib.docs.first?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.lib.docs.isEmpty {
                    ContentUnavailableView(
                        L("暂无闪卡文档"),
                        systemImage: "rectangle.on.rectangle.angled",
                        description: Text(L("先导入或通过 iCloud 同步 PDF 文档，即可让 AI 自动提炼间隔重复记忆闪卡。"))
                    )
                } else {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.lib.docs) { d in
                                    let active = activeDocId == d.id
                                    let deckCount = fs.decks(d.id).reduce(0) { $0 + $1.cards.count }
                                    Button {
                                        rc.bind(docId: d.id)
                                        DocWindows.shared.activeDocId = d.id
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc.text.fill")
                                                .font(.caption2)
                                            Text(d.title)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                                .frame(maxWidth: 180)
                                            if deckCount > 0 {
                                                Text("\(deckCount)")
                                                    .font(.caption2.monospacedDigit().weight(.bold))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(active ? Color.white.opacity(0.22) : MN.accent.opacity(0.12)))
                                                    .foregroundStyle(active ? Color.white : MN.accent)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(active ? MN.accent : MN.panel))
                                        .overlay(Capsule().stroke(active ? Color.clear : Color.primary.opacity(0.06), lineWidth: 0.6))
                                        .foregroundStyle(active ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .background(MN.shelf)

                        Divider()

                        if let docId = activeDocId {
                            iOSMobileFlashcardsContent(store: store, rc: rc, docId: docId)
                                .id(docId)
                        }
                    }
                    .onAppear {
                        if rc.docId == nil, let first = store.currentDocId ?? store.lib.docs.first?.id {
                            rc.bind(docId: first)
                            DocWindows.shared.activeDocId = first
                        }
                    }
                }
            }
            .background(MN.shelf)
            .navigationTitle(L("AI 学习闪卡"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct iOSMobileFlashcardsContent: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let docId: UUID
    @ObservedObject private var fs = FlashStore.shared

    @State private var selectedDeckIndex: Int? = nil
    @State private var count: Int = 12
    @State private var scope: Int = 0 // 0 = 全文, 1 = 当前页 ±2 页

    private var decks: [FlashDeck] { fs.decks(docId) }

    var body: some View {
        ZStack {
            MN.shelf.ignoresSafeArea()
            if let di = selectedDeckIndex, di < decks.count {
                iOSMobileDeckStudyView(
                    docId: docId,
                    deckIndex: di,
                    deck: decks[di],
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDeckIndex = nil
                        }
                    }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        generatorCard
                        if decks.isEmpty && !fs.generating {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(MN.accent.opacity(0.10))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "rectangle.on.rectangle.angled")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(MN.accent)
                                }
                                Text(L("还没有卡组。生成后可以像翻卡片一样自测，标记「记住了 / 再看看」，进度会保存。"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                            .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
                        } else {
                            VStack(spacing: 12) {
                                ForEach(Array(decks.enumerated()), id: \.offset) { i, d in
                                    let known = d.cards.filter { $0.status == 2 }.count
                                    let allMastered = known == d.cards.count && !d.cards.isEmpty
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedDeckIndex = i
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "rectangle.stack.fill")
                                                    .font(.subheadline)
                                                    .foregroundStyle(MN.accent)
                                                Text(d.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            HStack {
                                                Text("\(L(d.scope)) · " + LF("%d 张", d.cards.count))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(LF("已掌握 %d/%d", known, d.cards.count))
                                                    .font(.caption.monospacedDigit().weight(.medium))
                                                    .foregroundStyle(allMastered ? .green : MN.accent)
                                            }
                                            ProgressView(value: Double(known), total: Double(max(1, d.cards.count)))
                                                .tint(allMastered ? .green : MN.accent)
                                        }
                                        .padding(14)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(L("删除卡组"), role: .destructive) {
                                            fs.deleteDeck(docId, i)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var generatorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(MN.accent)
                    Text(L("生成新卡组"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        if count > 5 { count -= 1 }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(LF("%d 张", count))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 42)
                    Button {
                        if count < 30 { count += 1 }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(MN.accent)
                    }
                }
            }

            Picker(L("范围"), selection: $scope) {
                Text(L("全文")).tag(0)
                Text(L("当前页 ±2 页")).tag(1)
            }
            .pickerStyle(.segmented)

            Button {
                guard let s = store.session(docId) else { return }
                let lo = max(0, min(rc.currentPageIndex - 2, s.pageCount - 1))
                let hi = max(lo, min(s.pageCount - 1, rc.currentPageIndex + 2))
                let r: ClosedRange<Int>? = scope == 0 ? nil : lo...hi
                fs.generate(docId: docId, doc: s.original, title: s.doc.title, pages: r, count: count)
            } label: {
                HStack(spacing: 8) {
                    if fs.generating {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(fs.generating ? L("生成中…") : L("生成 AI 学习闪卡"))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12).fill(MN.accent))
                .foregroundStyle(.white)
            }
            .disabled(fs.generating)

            if let e = fs.genError {
                Text("⚠️ " + e)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(MN.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
    }
}

struct iOSMobileDeckStudyView: View {
    let docId: UUID
    let deckIndex: Int
    let deck: FlashDeck
    let onBack: () -> Void

    @ObservedObject private var fs = FlashStore.shared
    @State private var order: [UUID] = []
    @State private var pos: Int = 0
    @State private var flipped: Bool = false
    @State private var onlyReview: Bool = false

    private var cards: [Flashcard] {
        order.compactMap { id in deck.cards.first { $0.id == id } }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "概念": return MN.accent
        case "应用": return .orange
        case "数据": return .teal
        default: return MN.accent
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L("全部卡组"))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MN.accent)
                }
                Spacer()
                Button {
                    onlyReview.toggle()
                    reset()
                } label: {
                    Text(L("只看未掌握"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(onlyReview ? MN.accent : MN.panel))
                        .overlay(Capsule().stroke(onlyReview ? Color.clear : Color.primary.opacity(0.08), lineWidth: 0.6))
                        .foregroundStyle(onlyReview ? Color.white : Color.primary)
                }
                Button {
                    order.shuffle()
                    pos = 0
                    flipped = false
                } label: {
                    Image(systemName: "shuffle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(Circle().fill(MN.panel))
                        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
                }
            }

            if cards.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(MN.accent)
                    Text(L("全部掌握了！"))
                        .font(.title3.weight(.semibold))
                    Button(L("重新学习全部")) {
                        onlyReview = false
                        reset()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MN.accent)
                }
                Spacer()
            } else if pos >= cards.count {
                Spacer()
                let known = deck.cards.filter { $0.status == 2 }.count
                VStack(spacing: 14) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 44))
                        .foregroundStyle(MN.accent)
                    Text(L("本轮完成"))
                        .font(.title3.weight(.semibold))
                    Text(LF("已掌握 %d/%d", known, deck.cards.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(L("复习未掌握")) {
                            onlyReview = true
                            reset()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MN.accent)

                        Button(L("再来一遍")) {
                            reset()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            } else {
                let c = cards[pos]
                HStack(spacing: 10) {
                    Text("\(pos + 1) / \(cards.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(pos + 1), total: Double(max(1, cards.count)))
                        .tint(MN.accent)
                }

                // 3D Flip Flashcard
                ZStack {
                    cardFace(c, front: true)
                        .opacity(flipped ? 0 : 1)
                    cardFace(c, front: false)
                        .opacity(flipped ? 1 : 0)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .onTapGesture {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        flipped.toggle()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom Study Controls
                HStack(spacing: 10) {
                    Button {
                        go(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 42, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(MN.panel))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
                    }
                    .disabled(pos == 0)

                    if flipped {
                        Button {
                            mark(c, 1)
                        } label: {
                            Label(L("再看看"), systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.14)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.28), lineWidth: 0.8))
                                .foregroundStyle(.orange)
                        }

                        Button {
                            mark(c, 2)
                        } label: {
                            Label(L("记住了"), systemImage: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(MN.accent))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                flipped = true
                            }
                        } label: {
                            Text(L("查看答案"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(MN.accent))
                                .foregroundStyle(.white)
                        }
                    }

                    Button {
                        go(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 42, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(MN.panel))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
                    }
                }
            }
        }
        .padding(16)
        .onAppear { reset() }
    }

    private func cardFace(_ card: Flashcard, front: Bool) -> some View {
        let kCol = kindColor(card.kind)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L(card.kind))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(kCol.opacity(0.12)))
                    .foregroundStyle(kCol)
                if let p = card.page {
                    Text("p.\(p)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(front ? L("问题") : L("答案"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(front ? card.question : card.answer)
                        .font(front ? .title3.weight(.semibold) : .body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !front, let exp = card.explanation, !exp.isEmpty {
                        Divider()
                        Text(exp)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Label(L("点击卡片翻转查看答案"), systemImage: "hand.tap")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(MN.panel)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(front ? Color.primary.opacity(0.08) : MN.accent.opacity(0.32), lineWidth: front ? 0.8 : 1.2)
        )
    }

    private func reset() {
        order = deck.cards.filter { !onlyReview || $0.status != 2 }.map(\.id)
        pos = 0
        flipped = false
    }

    private func go(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.22)) {
            pos = max(0, min(cards.count, pos + delta))
            flipped = false
        }
    }

    private func mark(_ card: Flashcard, _ status: Int) {
        fs.setStatus(docId, deck: deckIndex, card: card.id, status: status)
        go(1)
    }
}

// MARK: - Tab 4: Settings & iCloud Sync View

struct iOSSettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var cloud: CloudSync
    @ObservedObject var narrator = Narrator.shared
    @ObservedObject var lang = LangCenter.shared
    @ObservedObject var themeCenter = iOSThemeCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var baseURL = Settings.baseURL
    @State private var apiKey = Settings.apiKey
    @State private var showAPIKey = false
    @State private var translateModel = ModelConfig.translateModel
    @State private var translateStyle = ModelConfig.style("translate")
    @State private var chatModel = ModelConfig.chatModel
    @State private var chatStyle = ModelConfig.style("chat")
    @State private var targetLang = Settings.targetLang
    @State private var testStatus = ""
    @State private var isTesting = false
    @State private var showFolderPicker = false
    @State private var didLoadInitialSettings = false
    @State private var isReloadingFromStore = false
    @State private var hasLocalEdits = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("外观与语言")) {
                    Picker(L("语言"), selection: Binding(get: { lang.lang }, set: { lang.set($0) })) {
                        ForEach(UILang.allCases) { l in
                            Text(l.name).tag(l)
                        }
                    }
                    Picker(L("界面主题"), selection: Binding(get: { themeCenter.theme }, set: { themeCenter.set($0) })) {
                        ForEach(AppTheme.allCases) { t in
                            Text(t.name).tag(t)
                        }
                    }
                }

                Section {
                    Toggle(L("启用 iCloud 多端自动同步"), isOn: $cloud.isEnabled)
                    HStack {
                        Label(L("同步状态"), systemImage: cloud.state.isSyncing ? "arrow.triangle.2.circlepath.icloud.fill" : "checkmark.icloud.fill")
                        Spacer()
                        if cloud.state.isSyncing {
                            ProgressView().controlSize(.small)
                        } else if let dt = cloud.lastSyncedAt {
                            Text(dt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L("已就绪"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(L("已同步内容"))
                        Spacer()
                        Text(LF("%d 篇文档 · %d 张摘录卡片 · %d 个笔记本", store.lib.docs.count, store.lib.cards.count, store.lib.notebooks.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        saveSettings()
                        cloud.syncNow(silent: false)
                    } label: {
                        Label(L("立即与 Mac / iCloud 同步"), systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label(L("选择 iCloud Drive 同步目录…"), systemImage: "folder.badge.gearshape")
                    }
                    if !cloud.cloudLocationDescription.isEmpty {
                        Text(cloud.cloudLocationDescription)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("iCloud 多端同步（iPhone · iPad · Mac）"))
                } footer: {
                    Text(L("在 Mac 或 iPhone 上导入的 PDF、讲解稿、摘录批注、笔记本、阅读进度及网关配置会自动通过 iCloud 双向合并同步；语音与视频文件仅保存在本机。"))
                }

                Section(L("AI 网关与模型配置")) {
                    LabeledContent(L("网关地址")) {
                        TextField("https://api.anthropic.com", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("API Key") {
                        HStack(spacing: 6) {
                            Group {
                                if showAPIKey {
                                    TextField("sk-...", text: $apiKey)
                                } else {
                                    SecureField("sk-...", text: $apiKey)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)

                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    LabeledContent(L("翻译模型")) {
                        TextField("claude-haiku-5-5", text: $translateModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Picker(L("翻译接口协议"), selection: $translateStyle) {
                        ForEach(APIStyle.available) { st in
                            Text(st.name).tag(st)
                        }
                    }
                    LabeledContent(L("AI 解读/助手模型")) {
                        TextField("claude-haiku-5-5", text: $chatModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Picker(L("助手接口协议"), selection: $chatStyle) {
                        ForEach(APIStyle.available) { st in
                            Text(st.name).tag(st)
                        }
                    }
                    Picker(L("翻译目标语言"), selection: $targetLang) {
                        ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"], id: \.self) { lg in
                            Text(lg).tag(lg)
                        }
                    }
                    HStack {
                        Button {
                            saveSettings()
                            testConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if isTesting { ProgressView().controlSize(.small) }
                                Text(L("保存并测试网关连接"))
                            }
                        }
                        .disabled(isTesting)
                        Spacer()
                    }
                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundStyle(testStatus.hasPrefix("✅") ? .green : .red)
                    }
                }

                iOSVoiceSettingsSection(targetLang: targetLang)
                iOSStorageManagementSection(store: store)
            }
            .scrollContentBackground(.hidden)
            .background(MN.shelf)
            .navigationTitle(L("设置与同步"))
            .onAppear {
                if !didLoadInitialSettings {
                    didLoadInitialSettings = true
                    reloadFromSettings()
                }
            }
            .onChange(of: cloud.lastSyncedAt) { _, _ in
                if !hasLocalEdits {
                    reloadFromSettings()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active && hasLocalEdits {
                    saveSettings()
                }
            }
            .onChange(of: baseURL) { _, _ in autoSaveFieldEdit() }
            .onChange(of: apiKey) { _, _ in autoSaveFieldEdit() }
            .onChange(of: translateModel) { _, _ in autoSaveFieldEdit() }
            .onChange(of: translateStyle) { _, _ in autoSaveFieldEdit() }
            .onChange(of: chatModel) { _, _ in autoSaveFieldEdit() }
            .onChange(of: chatStyle) { _, _ in autoSaveFieldEdit() }
            .onChange(of: targetLang) { _, _ in autoSaveFieldEdit() }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { res in
                if case .success(let urls) = res, let u = urls.first {
                    cloud.setCustomCloudFolder(u)
                }
            }
        }
    }

    private func autoSaveFieldEdit() {
        guard !isReloadingFromStore else { return }
        hasLocalEdits = true
        saveSettings(syncImmediately: false)
    }

    private func reloadFromSettings() {
        isReloadingFromStore = true
        defer { isReloadingFromStore = false }
        baseURL = Settings.baseURL
        apiKey = Settings.apiKey
        translateModel = ModelConfig.translateModel
        translateStyle = ModelConfig.style("translate")
        chatModel = ModelConfig.chatModel
        chatStyle = ModelConfig.style("chat")
        targetLang = Settings.targetLang
    }

    private func saveSettings(syncImmediately: Bool = true) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            Settings.baseURL = trimmedBase
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            Settings.apiKey = trimmedKey
        }
        let trimmedTransModel = translateModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTransModel.isEmpty {
            ModelConfig.setModel("translate", trimmedTransModel)
        }
        ModelConfig.setStyle("translate", translateStyle)
        let trimmedChatModel = chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedChatModel.isEmpty {
            ModelConfig.setModel("chat", trimmedChatModel)
        }
        ModelConfig.setStyle("chat", chatStyle)
        Settings.targetLang = targetLang
        UserDefaults.standard.set(Date(), forKey: "icloud.settings.updatedAt")
        if syncImmediately {
            CloudSync.shared.recordSettingsChange()
        }
    }

    private func testConnection() {
        isTesting = true
        testStatus = L("正在测试连接…")
        Task {
            do {
                let t = try await Translator.translateOne("Attention is all you need.")
                testStatus = "✅ " + L("连接成功：") + t
            } catch {
                testStatus = "❌ " + error.localizedDescription
            }
            isTesting = false
        }
    }
}

/// Reusable iOS Voice & Narration settings section with progressive disclosure.
/// Exposes primary voice (`音色`) and voice source (`音色来源`) pickers cleanly, while tucking
/// provider-specific endpoints, keys, models, custom voice IDs, and extra prompts inside a collapsible group.
struct iOSVoiceSettingsSection: View {
    let targetLang: String
    var startExpanded: Bool = false

    @ObservedObject private var narrator = Narrator.shared
    @ObservedObject private var cloud = CloudSync.shared

    @State private var ttsProvider: TTSProvider = Settings.ttsProvider
    @State private var sysVoice: String = Settings.systemVoice
    @State private var tts: TTSFields = TTSFields.load(Settings.ttsProvider)
    @State private var ttsSpeed: Float = Settings.ttsSpeed
    @State private var narrationStyle: NarrationStyle = Settings.narrationStyle
    @State private var narrationExtraPrompt: String = Settings.narrationExtraPrompt
    @State private var showAdvancedTTS: Bool = false
    @State private var showProviderKey: Bool = false
    @State private var isPreviewingTTS: Bool = false
    @State private var previewStatus: String = ""
    @State private var isReloading: Bool = false
    @State private var didAppear: Bool = false

    var body: some View {
        Section {
            Picker(L("音色来源"), selection: $ttsProvider) {
                ForEach(TTSProvider.allCases) { p in
                    Text(L(p.title)).tag(p)
                }
            }

            if ttsProvider == .system {
                let sysOptions = SystemTTS.options(for: targetLang)
                Picker(L("音色 (Voice)"), selection: $sysVoice) {
                    Text(L("自动（按目标语言）")).tag("")
                    if !sysVoice.isEmpty && !sysOptions.contains(where: { $0.id == sysVoice }) {
                        Text(sysVoice).tag(sysVoice)
                    }
                    ForEach(sysOptions) { v in
                        Text(v.label).tag(v.id)
                    }
                }
            } else {
                let suggestions = ttsProvider.voiceSuggestions
                Picker(L("音色 (Voice)"), selection: $tts.voice) {
                    if !tts.voice.isEmpty && !suggestions.contains(where: { $0.id == tts.voice }) {
                        Text("\(tts.voice) (\(L("自定义")))").tag(tts.voice)
                    }
                    ForEach(suggestions) { v in
                        Text(L(v.label)).tag(v.id)
                    }
                }
            }

            Picker(L("讲解风格"), selection: $narrationStyle) {
                ForEach(NarrationStyle.allCases) { st in
                    Text(L(st.title) + " — " + L(st.subtitle)).tag(st)
                }
            }

            Picker(L("默认倍速"), selection: $ttsSpeed) {
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { spd in
                    Text(String(format: "%.2gx", spd)).tag(spd)
                }
            }

            DisclosureGroup(isExpanded: $showAdvancedTTS) {
                if ttsProvider == .system {
                    if SystemTTS.hasOnlyCompactVoices {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(L("当前只有基础系统声音，听起来可能较机械。可在系统「设置 → 辅助功能 → 朗读内容 → 声音」中免费下载「增强」或「高级」版声音。"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(L("更自然的系统声音可在「设置 → 辅助功能 → 朗读内容 → 声音」中下载，推荐「高级」或「增强」版本。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    remoteProviderConfigRows
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("补充提示词（可选）"))
                        .font(.subheadline)
                    TextField(
                        L("例如：多结合代码讲解；每页结尾用一句话总结"),
                        text: $narrationExtraPrompt,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .font(.footnote)
                    Text(L("修改后新生成的讲解会采用新风格，已生成的旧风格内容会保留，切回去可直接复用。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } label: {
                HStack {
                    Label(L("音色来源配置与高级选项"), systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                    Spacer()
                    if !showAdvancedTTS {
                        Text(ttsProvider == .system ? L("系统声音 / 提示词") : (tts.model.isEmpty ? ttsProvider.defaultModel : tts.model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Button {
                previewVoice()
            } label: {
                HStack(spacing: 8) {
                    if isPreviewingTTS {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    Text(isPreviewingTTS ? L("合成中…") : L("试听当前语音"))
                }
            }
            .disabled(isPreviewingTTS)

            if !previewStatus.isEmpty {
                Text(previewStatus)
                    .font(.caption)
                    .foregroundStyle(previewStatus.hasPrefix("✅") ? .green : (previewStatus.hasPrefix("❌") ? .red : .secondary))
            }
        } header: {
            Text(L("AI 语音讲解 (TTS)"))
        } footer: {
            if ttsProvider.isRemote {
                Text(L("请求失败（如没有模型、Key 无效）时，讲解会自动改用系统语音。"))
            }
        }
        .onAppear {
            if !didAppear {
                didAppear = true
                showAdvancedTTS = startExpanded
                reloadFromStore()
            }
        }
        .onChange(of: ttsProvider) { old, new in
            guard !isReloading else { return }
            tts.save(old)
            isReloading = true
            tts = TTSFields.load(new)
            isReloading = false
            if new.needsOwnKey && tts.key.isEmpty {
                withAnimation { showAdvancedTTS = true }
            }
            saveToStore(syncImmediately: true)
        }
        .onChange(of: sysVoice) { _, _ in
            guard !isReloading else { return }
            saveToStore(syncImmediately: true)
        }
        .onChange(of: tts) { _, _ in
            guard !isReloading else { return }
            saveToStore(syncImmediately: false)
        }
        .onChange(of: ttsSpeed) { _, _ in
            guard !isReloading else { return }
            saveToStore(syncImmediately: true)
        }
        .onChange(of: narrationStyle) { _, _ in
            guard !isReloading else { return }
            saveToStore(syncImmediately: true)
        }
        .onChange(of: narrationExtraPrompt) { _, _ in
            guard !isReloading else { return }
            saveToStore(syncImmediately: false)
        }
        .onChange(of: narrator.provider) { _, newProvider in
            if newProvider != ttsProvider { reloadFromStore() }
        }
        .onChange(of: narrator.voice) { _, newVoice in
            if ttsProvider.isRemote && newVoice != tts.voice { reloadFromStore() }
        }
        .onChange(of: narrator.systemVoice) { _, newSysVoice in
            if newSysVoice != sysVoice { reloadFromStore() }
        }
        .onChange(of: cloud.lastSyncedAt) { _, _ in
            reloadFromStore()
        }
    }

    @ViewBuilder
    private var remoteProviderConfigRows: some View {
        let p = ttsProvider
        LabeledContent(L("自定义音色 ID")) {
            HStack(spacing: 6) {
                TextField(p.defaultVoice, text: $tts.voice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                if !p.voiceSuggestions.isEmpty {
                    Menu {
                        ForEach(p.voiceSuggestions) { v in
                            Button(L(v.label)) {
                                tts.voice = v.id
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption)
                            .foregroundStyle(MN.accent)
                    }
                }
            }
        }

        if p == .gateway {
            LabeledContent(L("地址与 Key"), value: L("使用「AI 网关与模型配置」"))
        } else {
            LabeledContent("Base URL") {
                TextField(p.defaultBaseURL.isEmpty ? p.baseURLHint : p.defaultBaseURL, text: $tts.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            if !p.baseURLHint.isEmpty && p.baseURLHint != p.defaultBaseURL {
                Text(L("留空使用默认：") + L(p.baseURLHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if tts.keyManaged {
                LabeledContent("API Key", value: L("由配置文件提供"))
            } else {
                LabeledContent(p == .volcengine ? "Access Token" : "API Key") {
                    HStack(spacing: 6) {
                        Group {
                            if showProviderKey {
                                TextField(p == .volcengine ? "Token..." : "sk-...", text: $tts.key)
                            } else {
                                SecureField(p == .volcengine ? "Token..." : "sk-...", text: $tts.key)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)

                        Button {
                            showProviderKey.toggle()
                        } label: {
                            Image(systemName: showProviderKey ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if let h = p.keyHelpURL, let u = URL(string: h) {
                            Link(L("获取"), destination: u)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }

        if p.needsRegion {
            LabeledContent(L("区域（Region）")) {
                TextField("eastasia / eastus…", text: $tts.region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        }

        if p.needsAppId {
            LabeledContent("App ID") {
                TextField("App ID", text: $tts.appId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        }

        if p != .azure {
            LabeledContent(p == .volcengine ? L("集群（Cluster）") : L("TTS 模型")) {
                TextField(p.defaultModel, text: $tts.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        }

        HStack(alignment: .top, spacing: 8) {
            Text(p.providerNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let u = URL(string: AppInfo.supportURL.absoluteString + "#tts-" + p.rawValue) {
                Link(L("详细步骤"), destination: u)
                    .font(.caption2.weight(.semibold))
            }
        }
    }

    private func reloadFromStore() {
        isReloading = true
        defer { isReloading = false }
        ttsProvider = Settings.ttsProvider
        sysVoice = Settings.systemVoice
        tts = TTSFields.load(ttsProvider)
        ttsSpeed = Settings.ttsSpeed
        narrationStyle = Settings.narrationStyle
        narrationExtraPrompt = Settings.narrationExtraPrompt
    }

    private func saveToStore(syncImmediately: Bool) {
        Settings.ttsProvider = ttsProvider
        Settings.systemVoice = sysVoice
        tts.save(ttsProvider)
        Settings.ttsSpeed = ttsSpeed
        if Settings.narrationStyle != narrationStyle {
            Settings.narrationStyle = narrationStyle
        }
        if Settings.narrationExtraPrompt != narrationExtraPrompt {
            Settings.narrationExtraPrompt = narrationExtraPrompt
        }
        if narrator.systemVoice != sysVoice {
            narrator.systemVoice = sysVoice
        }
        if narrator.provider != ttsProvider {
            narrator.provider = ttsProvider
        }
        let resolvedVoice = Settings.ttsVoice(ttsProvider)
        if narrator.voice != resolvedVoice {
            narrator.voice = resolvedVoice
        }
        if abs(narrator.rate - ttsSpeed) > 0.01 {
            narrator.rate = ttsSpeed
        }
        UserDefaults.standard.set(Date(), forKey: "icloud.settings.updatedAt")
        if syncImmediately {
            CloudSync.shared.recordSettingsChange()
        }
    }

    private func previewVoice() {
        saveToStore(syncImmediately: true)
        isPreviewingTTS = true
        previewStatus = L("合成中…")
        Task {
            do {
                try await narrator.previewVoice()
                previewStatus = "✅ " + L("试听")
            } catch {
                previewStatus = "❌ TTS: " + error.localizedDescription
            }
            isPreviewingTTS = false
        }
    }
}

/// Modal sheet for adjusting voice, voice source, and narration style directly from the reader or narration bar.
struct iOSVoiceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                iOSVoiceSettingsSection(targetLang: Settings.targetLang, startExpanded: false)
            }
            .scrollContentBackground(.hidden)
            .background(MN.shelf)
            .navigationTitle(L("语音与音色设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) {
                        CloudSync.shared.recordSettingsChange()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct iOSStorageManagementSection: View {
    @ObservedObject var store: Store
    @State private var usage: StorageManager.Usage?
    @State private var docUsages: [(Doc, StorageManager.DocMediaUsage)] = []
    @State private var statusMsg: String = ""

    var body: some View {
        Section {
            if let u = usage {
                LabeledContent(L("讲解语音缓存"), value: StorageManager.format(u.audio))
                LabeledContent(L("导出讲解视频"), value: StorageManager.format(u.video))
                LabeledContent(L("双语页面缓存"), value: StorageManager.format(u.bilingual))
                LabeledContent(L("PDF 原文件"), value: StorageManager.format(u.pdfs))
                LabeledContent(L("笔记、讲稿与翻译"), value: StorageManager.format(u.other))
                LabeledContent(L("合计"), value: StorageManager.format(u.total))
                    .fontWeight(.semibold)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("正在统计…")).foregroundStyle(.secondary)
                }
            }

            if !docUsages.isEmpty {
                DisclosureGroup(L("单篇文档音视频空间")) {
                    ForEach(docUsages, id: \.0.id) { doc, du in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text(LF("语音 %@ (%d 段) · 视频 %@ (%d 个) · 讲稿 %@", StorageManager.format(du.audioBytes), du.audioCount, StorageManager.format(du.videoBytes), du.videoCount, StorageManager.format(du.scriptBytes)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button {
                                    let freed = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: false)
                                    statusMsg = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                                    Task { await refresh() }
                                } label: {
                                    Label(L("清理语音与视频缓存"), systemImage: "waveform.slash")
                                }
                                Button {
                                    let freed = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: true)
                                    statusMsg = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                                    Task { await refresh() }
                                } label: {
                                    Label(L("清理语音、视频与双语缓存"), systemImage: "doc.badge.gearshape")
                                }
                                Button(role: .destructive) {
                                    let freed = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: true, includeBilingual: false)
                                    statusMsg = "✅ " + LF("已释放 %@ 空间", StorageManager.format(freed))
                                    Task { await refresh() }
                                } label: {
                                    Label(L("完全重置（含 AI 讲解稿）"), systemImage: "trash.slash")
                                }
                            } label: {
                                Text(L("重置"))
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(MN.accent.opacity(0.14)))
                                    .foregroundStyle(MN.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Button {
                Task {
                    await Task.detached(priority: .userInitiated) {
                        StorageManager.clearAudio()
                    }.value
                    for d in store.lib.docs {
                        _ = StorageManager.resetDocMedia(d.id, title: d.title, includeScripts: false, includeBilingual: false)
                    }
                    await refresh()
                }
            } label: {
                Label(L("清理全部语音与视频缓存"), systemImage: "trash")
            }

            if !statusMsg.isEmpty {
                Text(statusMsg)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text(L("存储与音频空间管理"))
        } footer: {
            Text(L("仅同步 PDF、讲解稿、摘录批注、笔记本与阅读进度；语音与视频文件仅保留在本地，不占用 iCloud 流量与空间。"))
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        let docs = store.lib.docs
        let (u, perDoc) = await Task.detached(priority: .utility) {
            let totalUsage = StorageManager.usage()
            var list: [(Doc, StorageManager.DocMediaUsage)] = []
            for d in docs {
                let du = StorageManager.docMediaUsage(d.id, title: d.title)
                if du.totalResettableBytes > 0 || du.bilingualBytes > 0 {
                    list.append((d, du))
                }
            }
            return (totalUsage, list)
        }.value
        usage = u
        docUsages = perDoc
    }
}

// MARK: - iOS Web URL to PDF Importer Sheet

struct iOSWebImportSheet: View {
    let onImported: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String = PlatformClipboard.string()?.hasPrefix("http") == true ? (PlatformClipboard.string() ?? "") : "https://"
    @State private var isImporting = false
    @State private var errorMsg = ""
    @State private var webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 1100))

    var body: some View {
        NavigationStack {
            Form {
                Section(L("网页文章链接")) {
                    TextField("https://...", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !errorMsg.isEmpty {
                    Section {
                        Text(errorMsg).foregroundStyle(.red).font(.caption)
                    }
                }
                Section {
                    Button {
                        Task { await convertWebToPDF() }
                    } label: {
                        HStack {
                            if isImporting { ProgressView().controlSize(.small) }
                            Text(isImporting ? L("正在加载网页并生成 PDF…") : L("导入为 PDF 文档"))
                        }
                    }
                    .disabled(isImporting || urlString.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
                }
            }
            .navigationTitle(L("从网页导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("取消")) { dismiss() }
                }
            }
        }
    }

    private func convertWebToPDF() async {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: clean) else {
            errorMsg = L("请输入有效的网址 URL")
            return
        }
        isImporting = true
        errorMsg = ""
        webView.load(URLRequest(url: u))
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        do {
            let pdfData = try await webView.pdf(configuration: WKPDFConfiguration())
            let rawTitle = (try? await webView.evaluateJavaScript("document.title") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false ? rawTitle! : (u.host ?? "Web Article"))
                .replacingOccurrences(of: "/", with: "-")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(title).pdf")
            try pdfData.write(to: tmp, options: .atomic)
            if let docId = Store.shared.importPDF(tmp, open: false) {
                Store.shared.setSource(docId, clean)
                isImporting = false
                dismiss()
                onImported(docId)
                return
            }
            errorMsg = L("生成的 PDF 无法解析")
        } catch {
            errorMsg = error.localizedDescription
        }
        isImporting = false
    }
}
#endif
