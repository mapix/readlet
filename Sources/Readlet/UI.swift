import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MarginNote 3–like themes: 默认 (light, dark toolbar) · 护眼 (warm sepia) · 夜间 (dark)
enum AppTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark
    var id: String { rawValue }
    var name: String { switch self { case .light: return L("默认"); case .sepia: return L("护眼"); case .dark: return L("夜间") } }
    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .light }
    var isDark: Bool { self == .dark }
}

/// Theme palette. Colours are read on every render, and the whole UI is re-rendered when the theme changes.
enum MN {
    static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color { Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a)) }
    static var t: AppTheme { AppTheme.current }
    static var bar: Color { switch t { case .light: return c(0.17, 0.17, 0.18); case .sepia: return c(0.36, 0.29, 0.22); case .dark: return c(0.11, 0.11, 0.12) } }
    static var barNS: NSColor { switch t { case .light: return NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1); case .sepia: return NSColor(srgbRed: 0.36, green: 0.29, blue: 0.22, alpha: 1); case .dark: return NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) } }
    static let barText = Color.white.opacity(0.88)
    static let barDim = Color.white.opacity(0.5)
    static var paper: Color { switch t { case .light: return c(0.93, 0.93, 0.92); case .sepia: return c(0.90, 0.86, 0.77); case .dark: return c(0.16, 0.16, 0.17) } }
    static var paperNS: NSColor { switch t { case .light: return NSColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1); case .sepia: return NSColor(srgbRed: 0.88, green: 0.83, blue: 0.73, alpha: 1); case .dark: return NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1) } }
    static var mapBG: Color { switch t { case .light: return c(0.965, 0.965, 0.955); case .sepia: return c(0.96, 0.93, 0.86); case .dark: return c(0.13, 0.13, 0.14) } }
    static var shelf: Color { switch t { case .light: return c(0.95, 0.95, 0.94); case .sepia: return c(0.95, 0.91, 0.83); case .dark: return c(0.12, 0.12, 0.13) } }
    static var panel: Color { switch t { case .light: return c(0.985, 0.985, 0.98); case .sepia: return c(0.97, 0.94, 0.88); case .dark: return c(0.17, 0.17, 0.18) } }
    /// bottom status bar: a lighter tone of the toolbar family per theme
    static var status: Color { switch t { case .light: return c(0.96, 0.96, 0.955); case .sepia: return c(0.92, 0.87, 0.78); case .dark: return c(0.14, 0.14, 0.15) } }
    static var statusText: Color { switch t { case .light: return c(0.42, 0.42, 0.44); case .sepia: return c(0.42, 0.34, 0.25); case .dark: return c(0.65, 0.65, 0.68) } }
    static var ink: Color { t.isDark ? c(0.9, 0.9, 0.9) : c(0.12, 0.12, 0.12) }
    static var accent: Color { switch t { case .sepia: return c(0.72, 0.45, 0.20); default: return c(0.24, 0.52, 0.96) } }
    static var scheme: ColorScheme { t.isDark ? .dark : .light }
}

#if os(macOS)
/// Page tint for the themes: a non-interactive overlay view above the PDF content using a compositing
/// filter (multiply for 护眼, difference for 夜间). Text stays vector-sharp, PDFKit is untouched.
final class TintOverlay: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    func update() {
        wantsLayer = true
        guard let l = layer else { return }
        switch AppTheme.current {
        case .light:
            isHidden = true
        case .sepia:
            isHidden = false
            l.backgroundColor = CGColor(srgbRed: 0.97, green: 0.91, blue: 0.80, alpha: 1)
            l.compositingFilter = "multiplyBlendMode"
        case .dark:
            isHidden = false
            l.backgroundColor = CGColor(gray: 0.92, alpha: 1)
            l.compositingFilter = "differenceBlendMode"
        }
    }
}

enum PageTint {
    static func apply(to view: PDFView) {
        view.backgroundColor = MN.paperNS
        guard let sup = view.superview else { return }
        let o = (sup.subviews.first { $0 is TintOverlay } as? TintOverlay) ?? {
            let t = TintOverlay(frame: view.frame)
            t.autoresizingMask = [.width, .height]
            sup.addSubview(t, positioned: .above, relativeTo: view)
            return t
        }()
        o.frame = view.frame
        o.update()
    }
}

enum StudyLayout: String { case split, reader, map }

/// Main window: notebook shelf → notebook page (its PDFs) → each PDF opens in its own window.
struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var theme = ThemeCenter.shared
    @ObservedObject var lang = LangCenter.shared
    var body: some View {
        LibraryView(store: store)
            .id("\(theme.theme)-\(lang.lang)")
            .background(WindowConfigurator())
            .environment(\.colorScheme, MN.scheme)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { u, _ in
                        if let u { DispatchQueue.main.async { importFiles([u]) } }
                    }
                }
                return true
            }
            .navigationTitle("Readlet")
    }
}

/// hides the title bar so our dark toolbar sits at the top like MarginNote
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.backgroundColor = MN.barNS
            w.toolbar = nil
            w.identifier = NSUserInterfaceItemIdentifier("library")
            w.minSize = NSSize(width: 720, height: 480)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Restores standard macOS titlebar double-click (Zoom / Minimize) and drag behavior on our custom 40pt fullSizeContentView top bar.
struct TitlebarInteraction: NSViewRepresentable {
    final class BarView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" {
                    window?.performMiniaturize(nil)
                } else if action != "None" {
                    window?.zoom(nil)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { BarView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - study toolbar (dark, MarginNote style)

struct StudyToolbar: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    @Binding var layoutRaw: String
    @Binding var showOutline: Bool
    @Binding var showCopilot: Bool

    var body: some View {
        HStack(spacing: 14) {
            Spacer().frame(width: 64) // traffic lights
            TB(icon: "square.grid.2x2", tip: L("显示文档库")) { showLibrary() }
                .layoutPriority(2)
            TB(icon: "sidebar.left", tip: L("大纲 / 卡片列表"), on: showOutline) { showOutline.toggle() }
                .layoutPriority(2)
            Menu {
                if let nb = store.lib.notebooks.first(where: { $0.docIds.contains(rc.docId ?? UUID()) }) {
                    Section(nb.name) {
                        ForEach(nb.docIds, id: \.self) { id in
                            if let d = store.doc(id) {
                                Button { DocWindows.shared.open(id) } label: { Label(d.title, systemImage: rc.docId == id ? "checkmark" : "doc") }
                            }
                        }
                    }
                }
                Divider()
                Button(L("重命名当前文档…")) { if let id = rc.docId { renameDocPrompt(id) } }
                Button(L("添加文档到笔记本…")) { importPanel() }
                Button(L("从网页导入…")) { WebImportPanel.show(notebook: store.currentNotebookId) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(rc.docId.flatMap { store.doc($0)?.title } ?? L("文档")).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(MN.barText)
                .frame(minWidth: 60, maxWidth: 260, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .layoutPriority(0)
            .help(rc.docId.flatMap { store.doc($0)?.title } ?? "")

            if let docId = rc.docId, let d = store.doc(docId) {
                DocTagMenuBadge(store: store, doc: d)
            }

            Spacer(minLength: 8)

            // reading mode
            HStack(spacing: 0) {
                seg(L("原文"), rc.variant == .original) { rc.setVariant(.original) }
                seg(L("双语"), rc.variant == .bilingual) { rc.setVariant(.bilingual) }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
            .fixedSize()
            .layoutPriority(3)

            Spacer(minLength: 8)

            // 阅读 / 标注 mode
            HStack(spacing: 0) {
                seg(L("阅读"), rc.readingMode) { rc.readingMode = true }
                seg(L("标注"), !rc.readingMode) { rc.readingMode = false }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
            .fixedSize()
            .help(L("阅读模式：选中文字不弹出摘录工具条；标注模式：选中即可摘录/批注"))
            // excerpt tools (MarginNote: 框选 + 自动摘录)
            if !rc.readingMode {
                TB(icon: "rectangle.dashed", tip: L("框选摘录（拖拽选取区域）"), on: rc.areaMode) { rc.areaMode.toggle() }
                TB(icon: "highlighter", tip: rc.autoExcerpt ? L("自动摘录：开（选中即摘录）") : L("自动摘录：关"), on: rc.autoExcerpt) { rc.autoExcerpt.toggle() }
                Circle().fill(Color(nsColor: highlightColors[rc.lastColor % highlightColors.count])).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white.opacity(0.6)))
                    .help(L("当前摘录颜色"))
            }
            // PDF Editing menu (truncate from position, erase region, delete pages, restore)
            Menu {
                Button {
                    rc.truncateMode.toggle()
                } label: {
                    Label(rc.truncateMode ? L("退出截断模式 (Esc)") : L("点击页面位置截断后面…"), systemImage: "scissors")
                }
                Button {
                    rc.eraseMode.toggle()
                } label: {
                    Label(rc.eraseMode ? L("退出框选擦除 (Esc)") : L("框选擦除页面区域…"), systemImage: "rectangle.dashed.and.paperclip")
                }
                if let docId = rc.docId, let ses = store.sessions[docId] {
                    Divider()
                    if ses.pageCount > 1 {
                        Button(role: .destructive) {
                            PDFEditor.deletePage(session: ses, pageIndex: rc.currentPageIndex)
                        } label: {
                            Label(LF("删除当前页 (p.%d)", rc.currentPageIndex + 1), systemImage: "trash")
                        }
                        if rc.currentPageIndex + 1 < ses.pageCount {
                            Button(role: .destructive) {
                                PDFEditor.deletePagesAfter(session: ses, pageIndex: rc.currentPageIndex)
                            } label: {
                                Label(L("删除当前页之后的所有页"), systemImage: "arrow.down.to.line")
                            }
                        }
                        if rc.currentPageIndex > 0 {
                            Button(role: .destructive) {
                                PDFEditor.deletePagesBefore(session: ses, pageIndex: rc.currentPageIndex)
                            } label: {
                                Label(L("删除当前页之前的所有页"), systemImage: "arrow.up.to.line")
                            }
                        }
                    }
                    if PDFEditor.hasBackup(docId) {
                        Divider()
                        Button {
                            PDFEditor.restoreOriginal(session: ses)
                        } label: {
                            Label(L("恢复原始未编辑 PDF"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            } label: {
                Image(systemName: "scissors")
                    .font(.system(size: 13))
                    .foregroundStyle((rc.truncateMode || rc.eraseMode) ? Color.white : MN.barDim)
                    .frame(width: 28, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill((rc.truncateMode || rc.eraseMode) ? Color.red.opacity(0.75) : Color.clear))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("编辑 PDF：从指定位置截断后面、擦除区域或删除多余页"))

            Divider().frame(height: 18).overlay(Color.white.opacity(0.2))
            // layout: reader | split | map
            HStack(spacing: 2) {
                TB(icon: "doc.richtext", tip: L("仅文档"), on: layoutRaw == StudyLayout.reader.rawValue) { layoutRaw = StudyLayout.reader.rawValue }
                TB(icon: "rectangle.split.2x1", tip: L("文档 + 脑图"), on: layoutRaw == StudyLayout.split.rawValue) { layoutRaw = StudyLayout.split.rawValue }
                TB(icon: "point.3.connected.trianglepath.dotted", tip: L("仅脑图"), on: layoutRaw == StudyLayout.map.rawValue) { layoutRaw = StudyLayout.map.rawValue }
            }
            Button {
                let n = Narrator.shared
                if n.state != .idle { n.stop(); rc.clearNarrationHighlight() }
                else if let id = rc.docId, let s = store.session(id) { n.start(docId: id, doc: s.document(rc.variant), title: s.doc.title, from: rc.currentPageIndex) }
            } label: {
                HStack(spacing: 4) { Image(systemName: "headphones"); Text(L("AI 解读")).font(.system(size: 12, weight: .semibold)) }
                    .foregroundStyle(MN.barText)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain).help(L("AI 逐页语音解读（⌘⇧L）"))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .fixedSize()
            TB(icon: "rectangle.on.rectangle.angled", tip: L("学习闪卡（⌘⇧K）")) { NotificationCenter.default.post(name: .openFlashcards, object: rc.docId) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button { showCopilot.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("AI").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(showCopilot ? Color.white : MN.barText)
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(showCopilot ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.1))))
            }
            .buttonStyle(.plain).help(L("AI 助手 (⌘J)"))
            .keyboardShortcut("j", modifiers: .command)
            .fixedSize()
            TB(icon: "pip.enter", tip: L("收起为桌面小组件（⌘⇧M）")) { MiniWidget.shared.collapse() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Menu {
                if let id = rc.docId, let s = store.sessions[id], !s.isComplete {
                    Button(L("翻译全文（后台）")) { s.translateWholeDocument(from: rc.currentPageIndex); rc.setVariant(.bilingual) }
                    Divider()
                }
                Button(L("AI 生成文档脑图")) { if let id = rc.docId { MapGenerator.shared.generate(docId: id); if layoutRaw == StudyLayout.reader.rawValue { layoutRaw = StudyLayout.split.rawValue } } }
                Divider()
                Button(L("导出双语 PDF…")) { exportBilingual() }
                Button(L("导出脑图为 Markdown…")) { exportMarkdown() }
                if let id = rc.docId, let d = store.doc(id) {
                    Divider()
                    DocProgressAndMediaMenuItems(store: store, doc: d, onJump: { p in rc.goToPage(p) })
                }
                Divider()
                Picker(L("主题"), selection: Binding(get: { AppTheme.current }, set: { ThemeCenter.shared.set($0) })) {
                    ForEach(AppTheme.allCases) { Text($0.name).tag($0) }
                }
                SettingsLink { Text(L("设置…")) }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(MN.barText) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(ZStack { MN.bar; TitlebarInteraction() }.ignoresSafeArea(.container, edges: .top))
    }

    func showLibrary() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }) { w.makeKeyAndOrderFront(nil) }
        else { NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil) }
    }

    func seg(_ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.black.opacity(0.85) : MN.barText)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.92) : Color.clear))
        }.buttonStyle(.plain)
    }
}

struct TB: View {
    let icon: String
    let tip: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .foregroundStyle(on ? Color.white : MN.barDim)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(tip)
        .fixedSize()
    }
}

// MARK: - Tag Helpers & Badges

func statusTagColor(_ st: DocStatusTag) -> Color {
    switch st {
    case .todo: return Color(nsColor: NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1))   // Blue
    case .doing: return Color(nsColor: NSColor(srgbRed: 0.90, green: 0.36, blue: 0.14, alpha: 1))  // Warm Orange
    case .done: return Color(nsColor: NSColor(srgbRed: 0.08, green: 0.68, blue: 0.44, alpha: 1))   // Emerald Green
    }
}

@MainActor func addCustomTagPrompt(_ docId: UUID) {
    let a = NSAlert()
    a.messageText = L("添加标签")
    a.informativeText = L("输入标签名称（如 TODO、DOING、DONE、Paper、精读 等）：")
    a.addButton(withTitle: L("确定"))
    a.addButton(withTitle: L("取消"))
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    f.placeholderString = "Paper / LLM / 必读"
    a.accessoryView = f
    a.window.initialFirstResponder = f
    if a.runModal() == .alertFirstButtonReturn {
        let parts = f.stringValue.split(whereSeparator: { $0 == "," || $0 == "，" }).map { String($0) }
        for p in parts { Store.shared.addTag(docId, p) }
    }
}

struct DocTagMenuBadge: View {
    @ObservedObject var store: Store
    let doc: Doc
    var body: some View {
        Menu {
            Section(L("阅读状态标签")) {
                ForEach(DocStatusTag.allCases) { st in
                    Button {
                        store.setStatusTag(doc.id, doc.statusTag == st ? nil : st)
                    } label: {
                        if doc.statusTag == st {
                            Label(st.label, systemImage: "checkmark")
                        } else {
                            Label(st.label, systemImage: st.icon)
                        }
                    }
                }
                if doc.statusTag != nil {
                    Button(L("清除状态标签")) { store.setStatusTag(doc.id, nil) }
                }
            }
            let allCustom = store.allCustomTags
            if !allCustom.isEmpty {
                Divider()
                Section(L("自定义标签")) {
                    ForEach(allCustom, id: \.self) { t in
                        let has = doc.customTags.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
                        Button {
                            store.toggleTag(doc.id, t)
                        } label: {
                            if has { Label("#" + t, systemImage: "checkmark") }
                            else { Text("#" + t) }
                        }
                    }
                }
            }
            Divider()
            Button(L("添加新标签…")) { addCustomTagPrompt(doc.id) }
        } label: {
            HStack(spacing: 4) {
                if let st = doc.statusTag {
                    Circle().fill(statusTagColor(st)).frame(width: 7, height: 7)
                    Text(st.label).font(.system(size: 10.5, weight: .bold))
                } else {
                    Image(systemName: "tag").font(.system(size: 10))
                    Text(L("标签")).font(.system(size: 10.5))
                }
                if let firstCustom = doc.customTags.first {
                    Text("#" + firstCustom).font(.system(size: 10)).opacity(0.85)
                }
            }
            .foregroundStyle(MN.barText)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("点击设置文档标签（TODO / DOING / DONE 或自定义标签）"))
    }
}

// MARK: - library (MarginNote "文档 / 学习" home)

struct LibraryView: View {
    @ObservedObject var store: Store
    @ObservedObject var wins = DocWindows.shared
    @ObservedObject var updater = UpdateChecker.shared
    @ObservedObject var cloud = CloudSync.shared
    @State private var tab = 0
    @State private var openNotebook: UUID?
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var selectedTagFilter: String = "ALL"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer().frame(width: 64)
                if let id = openNotebook, let nb = store.lib.notebooks.first(where: { $0.id == id }) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { openNotebook = nil } } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text(L("笔记本")) }
                    }.buttonStyle(.plain).foregroundStyle(MN.barText).fixedSize()
                    Text(nb.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                } else {
                    HStack(spacing: 0) { libTab(L("学习"), 0); libTab(L("文档"), 1) }
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Button { cloud.syncNow() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cloud.state.isSyncing ? "arrow.triangle.2.circlepath.icloud.fill" : (cloud.isEnabled ? "checkmark.icloud.fill" : "icloud.slash"))
                            .font(.system(size: 11.5))
                        Text(cloud.state.isSyncing ? L("同步中…") : "iCloud")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(cloud.isEnabled ? Color.cyan : MN.barDim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(cloud.cloudLocationDescription.isEmpty ? L("点击立即同步 iCloud（Mac 与 iPhone 自动同步）") : "iCloud: \(cloud.cloudLocationDescription)")
                if let rel = updater.availableRelease {
                    Button { updater.openDownload(for: rel) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text(LF("新版本 %@", rel.version)).font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                Button { importInto(openNotebook) } label: { Label(L("导入 PDF"), systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(MN.barText).fixedSize()
                Button { WebImportPanel.show(notebook: openNotebook) } label: { Label(L("从网页导入"), systemImage: "globe") }
                    .buttonStyle(.plain).foregroundStyle(MN.barText).fixedSize()
                    .help(L("粘贴文章链接，提取正文生成 PDF（⌘⇧O）"))
                if tab == 0 && openNotebook == nil {
                    Button { store.newNotebook() } label: { Label(L("新建笔记本"), systemImage: "book.closed") }
                        .buttonStyle(.plain).foregroundStyle(MN.barText).fixedSize()
                }
                LangMenu()
                ThemeMenu()
                Button { OnboardingPanel.show() } label: {
                    Image(systemName: "sparkles").foregroundStyle(MN.barText)
                }
                .buttonStyle(.plain)
                .help(L("打开设置向导"))
                SettingsLink { Image(systemName: "gearshape").foregroundStyle(MN.barText) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(ZStack { MN.bar; TitlebarInteraction() }.ignoresSafeArea(.container, edges: .top))

            if (tab == 1 || openNotebook != nil) && !store.lib.docs.isEmpty {
                let scopeDocs: [Doc] = {
                    if let id = openNotebook, let nb = store.lib.notebooks.first(where: { $0.id == id }) {
                        return nb.docIds.compactMap { store.doc($0) }
                    }
                    return store.lib.docs
                }()
                if !scopeDocs.isEmpty {
                    tagFilterAndRatioBar(docs: scopeDocs)
                }
            }

            ScrollView {
                if let id = openNotebook, let nb = store.lib.notebooks.first(where: { $0.id == id }) {
                    notebookPage(nb)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26)], spacing: 30) {
                        if tab == 0 {
                            ForEach(store.lib.notebooks) { nb in notebookTile(nb) }
                        } else {
                            ForEach(filteredDocs(store.lib.docs)) { d in docTile(d, notebook: nil) }
                            importTile(nil)
                            webImportTile(nil)
                        }
                    }
                    .padding(30)
                }
            }
            .background(MN.shelf)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNotebook)) { n in if let id = n.object as? UUID { openNotebook = id; tab = 0 } }
    }

    func filteredDocs(_ docs: [Doc]) -> [Doc] {
        switch selectedTagFilter {
        case "ALL":
            return docs
        case "UNTAGGED":
            return docs.filter { $0.tags.isEmpty }
        default:
            return docs.filter { d in
                d.tags.contains { $0.caseInsensitiveCompare(selectedTagFilter) == .orderedSame }
            }
        }
    }

    @ViewBuilder
    func tagFilterAndRatioBar(docs: [Doc]) -> some View {
        let total = max(1, docs.count)
        let todoCount = docs.filter { $0.statusTag == .todo }.count
        let doingCount = docs.filter { $0.statusTag == .doing }.count
        let doneCount = docs.filter { $0.statusTag == .done }.count
        let untaggedCount = docs.filter { $0.statusTag == nil }.count
        let todoPct = Int((Double(todoCount) / Double(total) * 100).rounded())
        let doingPct = Int((Double(doingCount) / Double(total) * 100).rounded())
        let donePct = Int((Double(doneCount) / Double(total) * 100).rounded())
        let avgReadPct = Int((docs.map(\.progressFraction).reduce(0, +) / Double(total) * 100).rounded())

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterPill(id: "ALL", title: L("全部"), count: docs.count, pct: nil, color: .secondary)
                        filterPill(id: "TODO", title: "TODO", count: todoCount, pct: todoPct, color: statusTagColor(.todo))
                        filterPill(id: "DOING", title: "DOING", count: doingCount, pct: doingPct, color: statusTagColor(.doing))
                        filterPill(id: "DONE", title: "DONE", count: doneCount, pct: donePct, color: statusTagColor(.done))
                        if untaggedCount > 0 {
                            filterPill(id: "UNTAGGED", title: L("未标记"), count: untaggedCount, pct: Int((Double(untaggedCount) / Double(total) * 100).rounded()), color: .gray)
                        }
                        ForEach(store.allCustomTags, id: \.self) { ct in
                            let c = docs.filter { d in d.customTags.contains { $0.caseInsensitiveCompare(ct) == .orderedSame } }.count
                            if c > 0 {
                                filterPill(id: ct, title: "#" + ct, count: c, pct: Int((Double(c) / Double(total) * 100).rounded()), color: .purple)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").font(.system(size: 11)).foregroundStyle(MN.accent)
                    Text(LF("平均阅读 %d%%", avgReadPct))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Proportional visual ratio bar for TODO / DOING / DONE / Untagged
            HStack(spacing: 10) {
                GeometryReader { g in
                    let w = g.size.width
                    let wTodo = w * CGFloat(todoCount) / CGFloat(total)
                    let wDoing = w * CGFloat(doingCount) / CGFloat(total)
                    let wDone = w * CGFloat(doneCount) / CGFloat(total)
                    HStack(spacing: 0) {
                        if todoCount > 0 { Rectangle().fill(statusTagColor(.todo)).frame(width: wTodo) }
                        if doingCount > 0 { Rectangle().fill(statusTagColor(.doing)).frame(width: wDoing) }
                        if doneCount > 0 { Rectangle().fill(statusTagColor(.done)).frame(width: wDone) }
                        if untaggedCount > 0 { Rectangle().fill(Color.secondary.opacity(0.25)) }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 6)

                Text("TODO \(todoPct)% · DOING \(doingPct)% · DONE \(donePct)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .overlay(Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5), alignment: .bottom)
    }

    private func filterPill(id: String, title: String, count: Int, pct: Int?, color: Color) -> some View {
        let active = selectedTagFilter.caseInsensitiveCompare(id) == .orderedSame
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTagFilter = (active && id != "ALL") ? "ALL" : id
            }
        } label: {
            HStack(spacing: 5) {
                if id != "ALL" {
                    Circle().fill(active ? .white : color).frame(width: 6.5, height: 6.5)
                }
                Text(title).font(.system(size: 11.5, weight: active ? .bold : .medium))
                if let pct {
                    Text("\(count) · \(pct)%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .opacity(active ? 0.92 : 0.72)
                } else {
                    Text("\(count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .opacity(active ? 0.92 : 0.72)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(active ? (id == "ALL" ? MN.accent : color) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    func importInto(_ nb: UUID?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = importableTypes
        p.allowsMultipleSelection = true
        p.message = L("PDF 直接导入；EPUB、Markdown、Word、RTF、HTML、TXT 会转换成 PDF")
        guard p.runModal() == .OK else { return }
        if let nb { store.currentNotebookId = nb }
        importFiles(p.urls, notebook: nb, open: false)
    }

    func libTab(_ t: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(t).font(.system(size: 12, weight: tab == i ? .semibold : .regular))
                .foregroundStyle(tab == i ? Color.black.opacity(0.85) : MN.barText)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(tab == i ? Color.white.opacity(0.92) : Color.clear))
        }.buttonStyle(.plain)
    }

    // notebook detail: its PDFs (click → open window) + a summary of cards
    func notebookPage(_ nb: Notebook) -> some View {
        let docs = filteredDocs(nb.docIds.compactMap { store.doc($0) })
        return VStack(alignment: .leading, spacing: 18) {
            let cards = store.lib.cards.filter { nb.docIds.contains($0.docId) }.count
            Text(LF("%d 个文档 · %d 张卡片 · 点击文档在新窗口中打开（可同时打开多个）", nb.docIds.count, cards))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26)], spacing: 30) {
                ForEach(docs) { d in docTile(d, notebook: nb.id) }
                importTile(nb.id)
                webImportTile(nb.id)
            }
        }
        .padding(30)
    }

    func notebookTile(_ nb: Notebook) -> some View {
        let first = nb.docIds.first.flatMap { store.doc($0) }
        let cards = store.lib.cards.filter { nb.docIds.contains($0.docId) }.count
        let nbDocs = nb.docIds.compactMap { store.doc($0) }
        let avgPct = nbDocs.isEmpty ? 0 : Int((nbDocs.map(\.progressFraction).reduce(0, +) / Double(nbDocs.count) * 100).rounded())
        return VStack(spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white).frame(width: 140, height: 186).offset(x: 6, y: -6).shadow(color: .black.opacity(0.08), radius: 2)
                Group {
                    if let d = first { Thumb(docId: d.id) } else {
                        ZStack { Color(nsColor: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.9, alpha: 1)); Image(systemName: "book.closed").font(.system(size: 34)).foregroundStyle(.orange.opacity(0.6)) }
                    }
                }
                .frame(width: 140, height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                Rectangle().fill(Color.orange.opacity(0.85)).frame(width: 8, height: 186)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4))
            }
            if renaming == nb.id {
                TextField(L("名称"), text: $draft, onCommit: { store.renameNotebook(nb.id, draft); renaming = nil })
                    .textFieldStyle(.roundedBorder).frame(width: 150)
            } else {
                Text(nb.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }
            Text(LF("%d 个文档 · %d 张卡片", nb.docIds.count, cards) + (nbDocs.isEmpty ? "" : " · \(avgPct)%"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { store.currentNotebookId = nb.id; openNotebook = nb.id } }
        .contextMenu {
            Button(L("打开")) { openNotebook = nb.id }
            Button(L("重命名")) { draft = nb.name; renaming = nb.id }
            Divider()
            Button(L("删除笔记本"), role: .destructive) { store.deleteNotebook(nb.id) }
        }
    }

    func docTile(_ d: Doc, notebook: UUID?) -> some View {
        let n = store.lib.cards.filter { $0.docId == d.id }.count
        let isOpen = wins.entries[d.id] != nil
        let pct = d.progressPercent
        let frac = CGFloat(d.progressFraction)
        let totalPages = d.pageCount ?? 0
        let readP = d.resolvedReadPage.map { min(max(1, $0 + 1), max(1, totalPages)) } ?? 0

        return VStack(spacing: 6) {
            Thumb(docId: d.id)
                .frame(width: 140, height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MN.accent, lineWidth: isOpen ? 2.5 : 0))
                // Top-left: Status tag badge (click to cycle TODO -> DOING -> DONE)
                .overlay(alignment: .topLeading) {
                    Button {
                        store.cycleStatusTag(d.id)
                    } label: {
                        if let st = d.statusTag {
                            Text(st.label)
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(statusTagColor(st)).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
                        } else {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(4)
                                .background(Circle().fill(Color.black.opacity(0.35)))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(L("点击切换状态标签（TODO → DOING → DONE）"))
                }
                // Top-right: Card count badge
                .overlay(alignment: .topTrailing) {
                    if n > 0 {
                        Text("\(n)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 6, y: -6)
                    }
                }
                // Bottom: Reading progress bar + percentage overlay
                .overlay(alignment: .bottom) {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text("\(pct)%")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Spacer()
                            if totalPages > 0 {
                                Text(readP > 0 ? "\(readP)/\(totalPages)p" : "\(totalPages)p")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.28))
                                Capsule()
                                    .fill(d.statusTag == .done ? statusTagColor(.done) : MN.accent)
                                    .frame(width: max(frac > 0 ? 4 : 0, g.size.width * frac))
                            }
                        }
                        .frame(height: 3.5)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4))
                }

            if renaming == d.id {
                TextField(L("文档名称"), text: $draft, onCommit: { store.renameDoc(d.id, draft); renaming = nil })
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .onExitCommand { renaming = nil }
            } else {
                Text(d.title).font(.system(size: 12)).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                    .onTapGesture(count: 2) { draft = d.title; renaming = d.id }
                    .help(L("双击重命名"))
            }

            // Custom tags & open state row
            HStack(spacing: 4) {
                if isOpen {
                    Text(L("已打开")).font(.system(size: 10, weight: .medium)).foregroundStyle(MN.accent)
                }
                ForEach(d.customTags.prefix(2), id: \.self) { ct in
                    Text("#" + ct)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
            }
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture { DocWindows.shared.open(d.id, notebook: notebook) }
        .contextMenu {
            Button(L("在新窗口打开")) { DocWindows.shared.open(d.id, notebook: notebook) }
            Divider()
            Menu(L("设置状态标签")) {
                ForEach(DocStatusTag.allCases) { st in
                    Button {
                        store.setStatusTag(d.id, d.statusTag == st ? nil : st)
                    } label: {
                        if d.statusTag == st { Label(st.label, systemImage: "checkmark") }
                        else { Text(st.label) }
                    }
                }
                if d.statusTag != nil {
                    Divider()
                    Button(L("清除状态标签")) { store.setStatusTag(d.id, nil) }
                }
            }
            Button(L("添加自定义标签…")) { addCustomTagPrompt(d.id) }
            if !d.customTags.isEmpty {
                Menu(L("移除标签")) {
                    ForEach(d.customTags, id: \.self) { ct in
                        Button("#" + ct) { store.removeTag(d.id, ct) }
                    }
                }
            }
            Divider()
            Button(L("重命名…")) { draft = d.title; renaming = d.id }
            Menu(L("加入笔记本")) {
                ForEach(store.lib.notebooks) { nb in Button(nb.name) { store.addDocToNotebook(d.id, notebook: nb.id) } }
            }
            if let nb = notebook { Button(L("从此笔记本移除")) { store.currentNotebookId = nb; store.removeDocFromNotebook(d.id) } }
            Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([Paths.pdf(d.id)]) }
            if let s = d.source, let u = URL(string: s) {
                Button(L("打开原网页")) { NSWorkspace.shared.open(u) }
                Button(L("重新从网页导入")) { WebImportPanel.show(notebook: notebook, url: s) }
            }
            Divider()
            DocProgressAndMediaMenuItems(store: store, doc: d, onJump: { p in
                store.restoreProgressSnapshot(d.id, page: p)
                DocWindows.shared.open(d.id, notebook: notebook)
            })
            Divider()
            Button(L("删除文档"), role: .destructive) { DocWindows.shared.close(d.id); store.deleteDoc(d.id) }
        }
    }

    func webImportTile(_ nb: UUID?) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.secondary)
                .frame(width: 140, height: 186)
                .overlay(VStack(spacing: 6) { Image(systemName: "globe").font(.system(size: 24)); Text(L("从网页导入")).font(.system(size: 12)) }.foregroundStyle(.secondary))
            Text(" ").font(.system(size: 12))
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture { WebImportPanel.show(notebook: nb) }
        .help(L("粘贴文章链接，提取正文生成 PDF（⌘⇧O）"))
    }

    func importTile(_ nb: UUID?) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.secondary)
                .frame(width: 140, height: 186)
                .overlay(VStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 26)); Text(L("导入 PDF")).font(.system(size: 12)) }.foregroundStyle(.secondary))
            Text(" ").font(.system(size: 12))
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture { importInto(nb) }
    }
}

extension Notification.Name { static let showNotebook = Notification.Name("showNotebook") }

struct DocProgressAndMediaMenuItems: View {
    @ObservedObject var store: Store
    let doc: Doc
    let onJump: (Int) -> Void

    var body: some View {
        Menu(L("多端阅读进度与恢复")) {
            if let conflict = doc.pendingConflict {
                Section(L("检测到多设备阅读进度冲突")) {
                    Button(LF("保留本机 (p.%d)", conflict.localPage + 1)) {
                        store.resolveProgressConflict(doc.id, useRemote: false)
                        onJump(conflict.localPage)
                    }
                    Button(LF("采用 %@ (p.%d)", conflict.remoteDeviceName, conflict.remotePage + 1)) {
                        store.resolveProgressConflict(doc.id, useRemote: true)
                        onJump(conflict.remotePage)
                    }
                }
            }
            Section(L("各设备阅读与讲解进度")) {
                if doc.deviceProgressHistory.isEmpty {
                    Text(L("暂无多设备同步记录"))
                } else {
                    ForEach(doc.deviceProgressHistory) { snap in
                        Button {
                            store.restoreProgressSnapshot(doc.id, page: snap.readPage, narrationPage: snap.narrationPage, narrationSeg: snap.narrationSeg)
                            onJump(snap.readPage)
                        } label: {
                            let narrText = snap.narrationPage.map { " · " + LF("讲解 p.%d · 第 %d 段", $0 + 1, (snap.narrationSeg ?? 0) + 1) } ?? ""
                            Text("\(snap.deviceName): p.\(snap.readPage + 1)\(narrText)")
                        }
                    }
                }
            }
            let daily = doc.dailyReadingLog.sorted { $0.key > $1.key }
            if !daily.isEmpty {
                Section(L("每日阅读足迹")) {
                    ForEach(daily.prefix(14), id: \.key) { day, p in
                        Button("\(day) — " + LF("阅读至 p.%d", p + 1)) {
                            store.restoreProgressSnapshot(doc.id, page: p)
                            onJump(p)
                        }
                    }
                }
            }
        }
        Menu(L("重置音频与视频空间")) {
            Button(L("清理语音与视频缓存")) {
                _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: false)
            }
            Button(L("清理语音、视频与双语缓存")) {
                _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: false, includeBilingual: true)
            }
            Divider()
            Button(L("完全重置（含 AI 讲解稿）"), role: .destructive) {
                _ = StorageManager.resetDocMedia(doc.id, title: doc.title, includeScripts: true, includeBilingual: false)
            }
        }
    }
}

struct MacProgressConflictBanner: View {
    let conflict: ProgressConflict
    let onKeepLocal: () -> Void
    let onAcceptRemote: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(L("检测到多设备阅读进度冲突") + " · " + LF("本机 (%@) 位于第 %d 页，另一设备 (%@) 位于第 %d 页", conflict.localDeviceName, conflict.localPage + 1, conflict.remoteDeviceName, conflict.remotePage + 1))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button(LF("保留本机 (p.%d)", conflict.localPage + 1), action: onKeepLocal)
                .controlSize(.small)
            Button(LF("采用 %@ (p.%d)", conflict.remoteDeviceName, conflict.remotePage + 1), action: onAcceptRemote)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14))
        .overlay(Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 0.5), alignment: .bottom)
    }
}

struct Thumb: View {
    let docId: UUID
    @State private var img: NSImage?
    @State private var editTick = 0
    var body: some View {
        ZStack {
            Color.white
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: "\(docId.uuidString)-\(editTick)") {
            let url = Paths.docDir(docId).appendingPathComponent("thumb.png")
            if let i = NSImage(contentsOf: url) { img = i; return }
            guard let d = PDFDocument(url: Paths.pdf(docId)), let p = d.safePage(0) else { return }
            let t = p.thumbnail(of: NSSize(width: 280, height: 372), for: .cropBox)
            img = t
            if let tiff = t.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidEdit)) { n in
            if (n.object as? UUID) == docId {
                img = nil
                editTick += 1
            }
        }
    }
}

// MARK: - reader pane

struct ReaderPane: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    @State private var showFind = false
    var body: some View {
        VStack(spacing: 0) {
            if let id = rc.docId, let s = store.session(id) {
                if let conflict = store.doc(id)?.pendingConflict {
                    MacProgressConflictBanner(
                        conflict: conflict,
                        onKeepLocal: { store.resolveProgressConflict(id, useRemote: false) },
                        onAcceptRemote: {
                            store.resolveProgressConflict(id, useRemote: true)
                            rc.goToPage(conflict.remotePage)
                        },
                        onDismiss: { store.dismissProgressConflict(id) }
                    )
                }
                ZStack(alignment: .topLeading) {
                    PDFReaderView(store: store, rc: rc)
                    ReaderOverlay(store: store, rc: rc)
                    if rc.variant == .bilingual { TranslateHUD(session: s, rc: rc) }
                    NarratorOverlay(docId: id)
                }
                .overlay(alignment: .topTrailing) {
                    if showFind { FindBar(rc: rc) { showFind = false }.padding(10).transition(.move(edge: .top).combined(with: .opacity)) }
                }
                .animation(.easeOut(duration: 0.15), value: showFind)
                .onReceive(NotificationCenter.default.publisher(for: .findInDocument)) { n in
                    if (n.object as? UUID) == id || (n.object == nil && DocWindows.shared.activeDocId == id) { showFind = true }
                }
                ReaderStatus(store: store, session: s, rc: rc)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text(L("此笔记本还没有文档")).font(.title3)
                    HStack(spacing: 10) {
                        Button(L("添加 PDF…")) { importPanel() }.buttonStyle(.borderedProminent)
                        Button(L("从网页导入…")) { WebImportPanel.show(notebook: store.currentNotebookId) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MN.paper)
            }
        }
    }
}

struct NarratorOverlay: View {
    let docId: UUID
    @ObservedObject var n = Narrator.shared
    @ObservedObject var w = MiniWidget.shared
    @AppStorage("narratorDock") private var dockRaw = NarratorDock.bottomCenter.rawValue
    var body: some View {
        let d = NarratorDock(rawValue: dockRaw) ?? .bottomCenter
        GeometryReader { geo in
            ZStack(alignment: d.alignment) {
                Color.clear.allowsHitTesting(false)
                if n.state != .idle && n.docId == docId && !w.active {
                    NarratorBar()
                        .frame(maxWidth: max(320, min(640, geo.size.width - 28)))
                        .padding(14)
                        .transition(.move(edge: d.edge).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: n.state == .idle)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: dockRaw)
        }
    }
}

/// Thin progress line at the top + a pill showing what is being translated right now.
struct TranslateHUD: View {
    @ObservedObject var session: DocSession
    @ObservedObject var rc: ReaderController
    @State private var hideDone = false

    var body: some View {
        let total = max(1, session.pageCount)
        let frac = CGFloat(session.doneCount) / CGFloat(total)
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.06))
                    Rectangle().fill(MN.accent).frame(width: g.size.width * frac)
                        .animation(.easeOut(duration: 0.35), value: frac)
                }
            }
            .frame(height: session.isComplete ? 0 : 3)
            HStack {
                Spacer()
                if let pill = pillText {
                    HStack(spacing: 7) {
                        if !session.isComplete { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(pill).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.black.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 8).padding(.trailing, 14)
            .animation(.easeInOut(duration: 0.2), value: pillText)
            Spacer()
        }
        .allowsHitTesting(false)
        .onChange(of: session.isComplete) { _, done in
            if done { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { hideDone = true } }
        }
        .onAppear { hideDone = session.isComplete }
    }

    var pillText: String? {
        let cur = rc.currentPageIndex
        if session.isComplete { return hideDone ? nil : L("全文翻译完成") }
        if let e = session.failedPages[cur] { return L("本页翻译失败：") + String(e.prefix(40)) }
        if let p = session.pageProgress[cur] { return LF("正在翻译第 %d 页 · %d/%d 段 · 全文 %d/%d", cur + 1, p.0, p.1, session.doneCount, session.pageCount) }
        if !session.translatedPages.contains(cur) { return LF("准备翻译第 %d 页… · 全文 %d/%d", cur + 1, session.doneCount, session.pageCount) }
        return LF("后台翻译中 · 全文 %d/%d", session.doneCount, session.pageCount)
    }
}

struct ReaderStatus: View {
    @ObservedObject var store: Store
    @ObservedObject var session: DocSession
    @ObservedObject var rc: ReaderController
    @State private var editingPage = false
    @State private var pageDraft = ""
    @FocusState private var pageFocus: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { rc.goToPage(max(0, rc.currentPageIndex - 1)) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help(L("上一页")).accessibilityLabel(L("上一页"))
            if editingPage {
                TextField("", text: $pageDraft).textFieldStyle(.roundedBorder).frame(width: 46).focused($pageFocus)
                    .onSubmit { if let n = Int(pageDraft) { rc.goToPage(min(session.pageCount, max(1, n)) - 1) }; editingPage = false }
                    .onAppear { pageDraft = "\(rc.currentPageIndex + 1)"; pageFocus = true }
                Text("/ \(session.pageCount)").monospacedDigit()
            } else {
                ReadProgress(page: rc.currentPageIndex, count: session.pageCount, onJump: { rc.goToPage($0) })
                    .onTapGesture(count: 2) { editingPage = true }
                    .help(L("拖动或点击跳转 · 双击输入页码"))
            }
            Button { rc.goToPage(min(session.pageCount - 1, rc.currentPageIndex + 1)) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help(L("下一页")).accessibilityLabel(L("下一页"))
            if rc.truncateMode {
                Spacer()
                Text(L("✂️ 截断模式：点击页面任意位置，截断此处下方及后续所有页（按 Esc 退出）")).foregroundStyle(.red)
            } else if rc.eraseMode {
                Spacer()
                Text(L("🧽 擦除模式：在页面上拖拽框选要擦除的区域（按 Esc 退出）")).foregroundStyle(.red)
            } else if rc.variant == .bilingual {
                if session.failedPages[rc.currentPageIndex] != nil {
                    Button(L("重试本页")) { Task { await session.retranslate(rc.currentPageIndex) } }.buttonStyle(.link)
                }
                Spacer()
                Text(session.progressText).monospacedDigit()
                Button { Task { await session.retranslate(rc.currentPageIndex) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help(L("重新翻译本页"))
            } else {
                Spacer()
                Text(rc.readingMode ? L("阅读模式：选中文字可复制，不会弹出标注") : (rc.areaMode ? L("框选模式：在页面上拖拽选取区域（Esc 退出）") : (rc.autoExcerpt ? L("自动摘录：选中文字即生成卡片") : L("选中文字 → 点颜色摘录 · 点击高亮打开卡片 · 右键可截断/编辑 PDF"))))
            }
            Divider().frame(height: 12)
            Button { rc.zoom(1 / 1.15) } label: { Image(systemName: "minus") }.buttonStyle(.plain).help(L("缩小 ⌘-")).accessibilityLabel(L("缩小 ⌘-"))
            Text("\(Int(rc.scalePercent))%").monospacedDigit().frame(width: 38).onTapGesture { rc.fitWidth() }.help(L("点击适合宽度"))
            Button { rc.zoom(1.15) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L("放大 ⌘=")).accessibilityLabel(L("放大 ⌘="))
        }
        .font(.system(size: 11))
        .foregroundStyle(MN.statusText)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(MN.status)
        .overlay(Rectangle().fill(Color.black.opacity(MN.t.isDark ? 0.4 : 0.08)).frame(height: 0.5), alignment: .top)
    }
}

// MARK: - outline / card list (MarginNote left "大纲" pane)

struct OutlinePane: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    @AppStorage("outlineMode") private var mode = 0
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) { Text(L("目录")).tag(2); Text(L("大纲")).tag(0); Text(L("卡片")).tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding(8)
            TextField(L("搜索"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mode == 2 {
                        TOCList(rc: rc, query: query)
                    } else if mode == 0, let nb = store.currentNotebook {
                        ForEach(flatten(nb.root, 0), id: \.0.id) { (n, d) in outlineRow(n, d) }
                    } else {
                        let ids = Set(store.currentNotebook?.docIds ?? [])
                        ForEach(store.lib.cards.filter { ids.contains($0.docId) && matches($0) }.sorted { ($0.docId.uuidString, $0.page) < ($1.docId.uuidString, $1.page) }) { c in cardRow(c) }
                    }
                }
            }
        }
        .background(MN.panel)
    }

    func matches(_ c: Card) -> Bool { query.isEmpty || c.text.localizedCaseInsensitiveContains(query) || (c.translation ?? "").localizedCaseInsensitiveContains(query) || c.commentText.localizedCaseInsensitiveContains(query) }

    func flatten(_ n: MindNode, _ d: Int) -> [(MindNode, Int)] {
        var out: [(MindNode, Int)] = []
        let t = store.nodeTitle(n)
        if query.isEmpty || t.localizedCaseInsensitiveContains(query) { out.append((n, d)) }
        for c in n.children { out += flatten(c, d + 1) }
        return out
    }

    func outlineRow(_ n: MindNode, _ d: Int) -> some View {
        let c = store.card(n.cardId)
        return HStack(alignment: .top, spacing: 6) {
            if let c { RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: highlightColors[c.color % highlightColors.count])).frame(width: 3, height: 15) }
            else { Image(systemName: d == 0 ? "book.closed" : "circle.fill").font(.system(size: d == 0 ? 11 : 4)).foregroundStyle(.secondary).frame(width: 8, height: 15) }
            Text(store.nodeTitle(n)).font(.system(size: d == 0 ? 13 : 12, weight: d == 0 ? .semibold : .regular)).lineLimit(2)
        }
        .padding(.leading, CGFloat(d) * 14 + 10).padding(.vertical, 5).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(store.selectedNodeId == n.id ? MN.accent.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedNodeId = n.id; store.mapFocusRequest = n.id
            if let c { store.jump(to: c) }
        }
    }

    func cardRow(_ c: Card) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: highlightColors[c.color % highlightColors.count])).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text.isEmpty ? L("［图片摘录］") : c.text).font(.system(size: 12)).lineLimit(3)
                Text("\(store.doc(c.docId)?.title ?? "") · p.\(c.page + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(store.selectedCardId == c.id ? MN.accent.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.jump(to: c); store.focusInMap(c.id) }
        .onDrag { NSItemProvider(object: ("card:" + c.id.uuidString) as NSString) }
    }
}


/// Broadcasts theme changes; windows observe it and re-render.
@MainActor
final class ThemeCenter: ObservableObject {
    static let shared = ThemeCenter()
    @Published var theme: AppTheme = .current
    func set(_ t: AppTheme) {
        UserDefaults.standard.set(t.rawValue, forKey: "theme")
        theme = t
        NSApp.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        for w in NSApp.windows { if !(w is NSPanel) { w.backgroundColor = MN.barNS } }
        for e in DocWindows.shared.entries.values { PageTint.apply(to: e.reader.view) }
    }
}

struct ThemeMenu: View {
    @ObservedObject var tc = ThemeCenter.shared
    var body: some View {
        Menu {
            ForEach(AppTheme.allCases) { t in
                Button { tc.set(t) } label: { if tc.theme == t { Label(t.name, systemImage: "checkmark") } else { Text(t.name) } }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(swatch(tc.theme)).frame(width: 11, height: 11).overlay(Circle().stroke(Color.white.opacity(0.6)))
                Text(tc.theme.name).font(.system(size: 12))
            }.foregroundStyle(MN.barText)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("主题"))
    }
    func swatch(_ t: AppTheme) -> Color { switch t { case .light: return .white; case .sepia: return MN.c(0.95, 0.89, 0.76); case .dark: return MN.c(0.2, 0.2, 0.22) } }
}


@MainActor func renameDocPrompt(_ id: UUID) {
    guard let d = Store.shared.doc(id) else { return }
    let a = NSAlert()
    a.messageText = L("重命名文档")
    a.addButton(withTitle: L("确定")); a.addButton(withTitle: L("取消"))
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    f.stringValue = d.title
    a.accessoryView = f
    a.window.initialFirstResponder = f
    if a.runModal() == .alertFirstButtonReturn { Store.shared.renameDoc(id, f.stringValue) }
}


/// reading progress: a slim bar with percentage; click / drag to jump
struct ReadProgress: View {
    let page: Int
    let count: Int
    let onJump: (Int) -> Void
    @State private var dragFrac: CGFloat?
    var frac: CGFloat { dragFrac ?? (count > 0 ? CGFloat(page + 1) / CGFloat(count) : 0) }
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(MN.statusText.opacity(0.18))
                    Capsule().fill(MN.accent).frame(width: max(5, g.size.width * frac))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragFrac = min(1, max(0, v.location.x / g.size.width)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / g.size.width))
                        onJump(min(count - 1, max(0, Int((f * CGFloat(count)).rounded(.up)) - 1)))
                        dragFrac = nil
                    })
            }
            .frame(width: 140, height: 14)
            Text("\(Int((frac * 100).rounded()))%").monospacedDigit().frame(width: 34, alignment: .leading)
            Text("\(dragFrac.map { Int(($0 * CGFloat(count)).rounded(.up)) } ?? page + 1)/\(count)").monospacedDigit().foregroundStyle(MN.statusText.opacity(0.7))
        }
    }
}
#endif
