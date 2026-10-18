#if os(macOS)
import SwiftUI
import AppKit

/// One NSWindow per open PDF. Opening an already-open document focuses its window.
@MainActor
final class DocWindows: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DocWindows()

    final class Entry {
        let docId: UUID
        let window: NSWindow
        let reader: ReaderController
        init(docId: UUID, window: NSWindow, reader: ReaderController) { self.docId = docId; self.window = window; self.reader = reader }
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    /// last focused document window (used by global features: narration, widget, AI)
    @Published var activeDocId: UUID?
    var active: Entry? { activeDocId.flatMap { entries[$0] } }

    func open(_ docId: UUID, notebook: UUID? = nil, jump: Card? = nil) {
        let store = Store.shared
        if let nb = notebook { store.currentNotebookId = nb }
        else if let nb = store.lib.notebooks.first(where: { $0.docIds.contains(docId) }) { store.currentNotebookId = nb.id }
        if let e = entries[docId] {
            e.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let j = jump { e.reader.jump(to: j) }
            return
        }
        guard let doc = store.doc(docId), store.session(docId) != nil else { return }
        let reader = ReaderController(docId: docId)
        let root = DocWindowView(store: store, rc: reader)
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = doc.title
        w.backgroundColor = MN.barNS
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.tabbingMode = .disallowed
        let key = "docwin-" + docId.uuidString
        w.setFrameAutosaveName(key)
        if !w.setFrameUsingName(key) {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: min(1400, vf.width * 0.85), height: min(950, vf.height * 0.9))
            // cascade from other windows
            let off = CGFloat(entries.count % 6) * 26
            w.setFrame(NSRect(x: vf.midX - size.width / 2 + off, y: vf.midY - size.height / 2 - off, width: size.width, height: size.height), display: false)
        }
        w.minSize = NSSize(width: 820, height: 560)
        entries[docId] = Entry(docId: docId, window: w, reader: reader)
        activeDocId = docId
        rememberOpen()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let j = jump { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reader.jump(to: j) } }
    }

    func close(_ docId: UUID) { entries[docId]?.window.performClose(nil) }

    func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, let e = entries.values.first(where: { $0.window === w }) else { return }
        activeDocId = e.docId
        if let nb = Store.shared.lib.notebooks.first(where: { $0.docIds.contains(e.docId) }), Store.shared.currentNotebookId != nb.id {
            Store.shared.currentNotebookId = nb.id
        }
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let e = entries.values.first(where: { $0.window === w }) else { return }
        if Narrator.shared.docId == e.docId { Narrator.shared.stop() }
        e.reader.unload()
        entries[e.docId] = nil
        if activeDocId == e.docId { activeDocId = entries.keys.first }
        if !terminating { rememberOpen() }
    }

    var terminating = false
    /// reopen the same documents on next launch
    private func rememberOpen() {
        UserDefaults.standard.set(entries.keys.map { $0.uuidString }, forKey: "openDocs")
    }
    func restore() {
        for s in UserDefaults.standard.stringArray(forKey: "openDocs") ?? [] {
            if let id = UUID(uuidString: s), Store.shared.doc(id) != nil { open(id) }
        }
    }

}

/// Content of a document window: toolbar + reader (+ mind map, copilot, outline, flashcards).
struct DocWindowView: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    @ObservedObject var theme = ThemeCenter.shared
    @ObservedObject var lang = LangCenter.shared
    @AppStorage("studyLayout") private var layoutRaw = StudyLayout.split.rawValue
    @AppStorage("showOutline") private var showOutline = false
    @AppStorage("showCopilot") private var showCopilot = false
    @AppStorage("copilotPanelWidth") private var copilotWidth: Double = 380
    @State private var showFlash = false

    var layout: StudyLayout { StudyLayout(rawValue: layoutRaw) ?? .split }

    var body: some View {
        VStack(spacing: 0) {
            StudyToolbar(store: store, rc: rc, layoutRaw: $layoutRaw, showOutline: $showOutline, showCopilot: $showCopilot)
            GeometryReader { geo in
                let maxPanel = max(Self.minCopilotWidth, Double(geo.size.width) - Self.minMainWidth)
                HStack(spacing: 0) {
                    if showOutline {
                        OutlinePane(store: store, rc: rc).frame(width: 260)
                        Divider()
                    }
                    Group {
                        switch layout {
                        case .reader: ReaderPane(store: store, rc: rc)
                        case .map: MindMapView(store: store)
                        case .split:
                            HSplitView {
                                ReaderPane(store: store, rc: rc).frame(minWidth: 420)
                                MindMapView(store: store).frame(minWidth: 300, idealWidth: 420)
                            }
                        }
                    }
                    if showCopilot {
                        PanelResizeHandle(width: $copilotWidth, minWidth: Self.minCopilotWidth, maxWidth: maxPanel)
                        CopilotPanel(store: store, rc: rc, open: $showCopilot)
                            .frame(width: min(max(copilotWidth, Self.minCopilotWidth), maxPanel))
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: showCopilot)
            }
        }
        .overlay { if showFlash { FlashcardsView(store: store, rc: rc, open: $showFlash).transition(.opacity) } }
        .animation(.easeInOut(duration: 0.18), value: showFlash)
        .onReceive(NotificationCenter.default.publisher(for: .openFlashcards)) { n in
            if (n.object as? UUID) == rc.docId || (n.object == nil && DocWindows.shared.activeDocId == rc.docId) { showFlash = true }
        }
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.colorScheme, MN.scheme)
        .id("\(theme.theme)-\(lang.lang)")          // rebuild with the new palette
    }

    static let minCopilotWidth: Double = 260
    static let minMainWidth: Double = 400
}

/// A vertical divider to the trailing edge of a side panel; drag it horizontally
/// to resize the panel. The line is 1pt wide but the hit area is widened to 7pt.
struct PanelResizeHandle: View {
    @Binding var width: Double
    var minWidth: Double
    var maxWidth: Double
    @State private var hovered = false
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 7)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(hovered ? AnyShapeStyle(MN.accent) : AnyShapeStyle(Color(nsColor: .separatorColor)))
                    .frame(width: hovered ? 2 : 1)
            }
            .contentShape(Rectangle())
            .onHover { h in
                hovered = h
                if h { NSCursor.resizeLeftRight.set() } else if startWidth == nil { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        NSCursor.resizeLeftRight.set()
                        let s = startWidth ?? width
                        startWidth = s
                        // panel sits on the trailing edge: dragging left grows it, right shrinks it
                        width = min(maxWidth, max(minWidth, s - Double(v.translation.width)))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        NSCursor.arrow.set()
                    }
            )
            .accessibilityLabel(L("调整 AI 助手栏宽度"))
            .accessibilityValue(Text("\(Int(width)) pt"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(maxWidth, width + 20)
                default: width = max(minWidth, width - 20)
                }
            }
    }
}
#endif
