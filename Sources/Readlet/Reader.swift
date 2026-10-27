#if os(macOS)
import SwiftUI
import PDFKit
import AppKit

/// PDFView with MarginNote-like mouse handling: selection finishes on mouse-up (then the floating bar appears),
/// clicking an excerpt highlight opens its card, and in "框选" mode a drag captures a rectangular region.
final class BiPDFView: PDFView {
    var onMenu: ((NSMenu, NSEvent) -> Void)?
    var onMouseDown: ((NSEvent) -> Bool)?      // return true to swallow
    var onMouseDragged: ((NSEvent) -> Bool)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)?
    var areaMode = false
    var eraseMode = false
    var truncateMode = false

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        onMenu?(m, event)
        return m
    }
    override func mouseDown(with e: NSEvent) {
        if onMouseDown?(e) == true { return }
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        if onMouseDragged?(e) == true { return }
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        if !areaMode && !eraseMode && !truncateMode { super.mouseUp(with: e) }
        onMouseUp?(e)
    }
    var onKey: ((NSEvent) -> Bool)?
    var hitCard: ((NSPoint) -> Bool)?
    override func keyDown(with e: NSEvent) {
        if onKey?(e) == true { return }
        super.keyDown(with: e)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if areaMode || eraseMode || truncateMode { addCursorRect(bounds, cursor: .crosshair) }
    }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        onMouseMoved?(e)
        guard !areaMode && !eraseMode && !truncateMode else { return }
        if hitCard?(convert(e.locationInWindow, from: nil)) == true { NSCursor.pointingHand.set() }
    }
}

/// rubber band drawn during area capture or region erase
final class BandView: NSView {
    var isErase = false
    override func draw(_ r: NSRect) {
        let col = isErase ? NSColor.systemRed : NSColor.systemBlue
        col.withAlphaComponent(0.14).setFill()
        bounds.fill()
        col.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1.2; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
    }
}

/// Horizontal cut-line preview drawn when `truncateMode` is active
final class CutLineView: NSView {
    var cutY: CGFloat = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard cutY > 0 && cutY < bounds.height else { return }
        // Shade the bottom area that will be truncated
        let shaded = NSRect(x: 0, y: 0, width: bounds.width, height: cutY)
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        shaded.fill()
        // Dashed red cut line
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: cutY))
        path.line(to: NSPoint(x: bounds.width, y: cutY))
        path.lineWidth = 2.0
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}

@MainActor
final class ReaderController: NSObject, ObservableObject {
    /// reader of the frontmost document window (most UI / AI features act on it)
    static var shared: ReaderController { DocWindows.shared.active?.reader ?? fallback }
    private static let fallback = ReaderController(docId: nil)
    let view = BiPDFView()
    let docId: UUID?
    /// per-window view mode
    @Published var variant: Variant = .original
    @Published var currentPageIndex = 0
    @Published var hasSelection = false
    @Published var popup: ReaderPopup = .none
    @Published var anchor: CGRect?            // in PDFView coords, top-left origin (for SwiftUI overlay)
    @Published var selectionString = ""
    @Published var scalePercent: CGFloat = 100
    /// height of floating UI over the bottom of the reader (narration player)
    var bottomInset: CGFloat = 0
    var topInset: CGFloat = 0
    /// 阅读模式: plain text selection, no excerpt bar / card popups / auto excerpt
    @Published var readingMode = UserDefaults.standard.bool(forKey: "readingMode") { didSet { UserDefaults.standard.set(readingMode, forKey: "readingMode"); if readingMode { closePopup(); areaMode = false; eraseMode = false; truncateMode = false } } }
    @Published var autoExcerpt = UserDefaults.standard.bool(forKey: "autoExcerpt") { didSet { UserDefaults.standard.set(autoExcerpt, forKey: "autoExcerpt") } }
    @Published var areaMode = false { didSet { view.areaMode = areaMode; if areaMode { eraseMode = false; truncateMode = false; closePopup() }; view.window?.invalidateCursorRects(for: view) } }
    @Published var eraseMode = false { didSet { view.eraseMode = eraseMode; if eraseMode { areaMode = false; truncateMode = false; closePopup() }; view.window?.invalidateCursorRects(for: view) } }
    @Published var truncateMode = false {
        didSet {
            view.truncateMode = truncateMode
            if truncateMode {
                areaMode = false; eraseMode = false; closePopup()
                let cl = CutLineView(frame: view.bounds)
                cl.autoresizingMask = [.width, .height]
                view.addSubview(cl)
                cutLineView = cl
            } else {
                cutLineView?.removeFromSuperview()
                cutLineView = nil
            }
            view.window?.invalidateCursorRects(for: view)
        }
    }
    var lastColor: Int {
        get { UserDefaults.standard.integer(forKey: "lastColor") }
        set { UserDefaults.standard.set(newValue, forKey: "lastColor"); objectWillChange.send() }
    }
    var loadedKey: String = ""
    private var popupPage: Int?
    private var popupRect: CGRect = .zero      // page coords of what the popup is attached to
    private var bandStart: NSPoint?
    private var band: BandView?
    private var cutLineView: CutLineView?
    private var contextMenuPointInView: NSPoint?

    init(docId: UUID?) {
        self.docId = docId
        super.init()
        if let d = docId { variant = Variant(rawValue: UserDefaults.standard.string(forKey: "variant-" + d.uuidString) ?? "") ?? .original }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = MN.paperNS
        view.pageShadowsEnabled = true
        view.displaysPageBreaks = true
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: view)
        view.onMenu = { [weak self] m, ev in self?.extendMenu(m, event: ev) }
        view.onMouseDown = { [weak self] e in self?.mouseDown(e) ?? false }
        view.onMouseDragged = { [weak self] e in self?.mouseDragged(e) ?? false }
        view.onMouseUp = { [weak self] e in self?.mouseUp(e) }
        view.onMouseMoved = { [weak self] e in self?.mouseMoved(e) }
        view.onKey = { [weak self] e in self?.key(e) ?? false }
        view.hitCard = { [weak self] pt in guard let self, !self.readingMode else { return false }; return self.cardAt(pt) != nil }
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] e in
            if let self, e.window === self.view.window { self.userScrolledAt = Date(); self.lastScroll = Date(); self.holdTarget = nil }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            let n = Narrator.shared
            guard let self, e.window === self.view.window else { return e }
            if n.listening {
                if e.type == .keyUp && e.keyCode == 49 {
                    n.endQuestion()
                    return nil
                }
                if e.type == .flagsChanged && !e.modifierFlags.contains(.control) {
                    n.endQuestion()
                    return e
                }
            }
            guard n.state == .playing, e.type == .keyDown, e.keyCode == 49, e.modifierFlags.contains(.control) else { return e }
            if !e.isARepeat { n.beginQuestion() }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53, e.window === self.view.window else { return e }    // Esc anywhere in the window
            if self.popup != .none || self.areaMode || self.eraseMode || self.truncateMode {
                self.closePopup(); self.areaMode = false; self.eraseMode = false; self.truncateMode = false
                self.view.clearSelection(); return nil
            }
            return e
        }
        DispatchQueue.main.async { self.observeScroll() }
    }

    private func observeScroll() {
        guard let clip = view.documentView?.enclosingScrollView?.contentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.observeScroll() }
            return
        }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
    }

    var store: Store { Store.shared }

    func load(session: DocSession, variant: Variant) {
        let key = session.doc.id.uuidString + variant.rawValue
        guard key != loadedKey else { return }
        closePopup()
        let keepPage = loadedKey.hasPrefix(session.doc.id.uuidString) ? currentPageIndex : nil
        loadedKey = key
        // read the saved page BEFORE swapping the document: setting view.document fires PDFViewPageChanged
        // for page 0, and pageChanged() would overwrite the stored position with 0
        let savedPage = store.doc(session.doc.id)?.resolvedReadPage
            ?? UserDefaults.standard.integer(forKey: "page-" + session.doc.id.uuidString)
        loading = true
        let d = session.document(variant)
        view.document = d
        let z = UserDefaults.standard.double(forKey: "zoom")
        if z > 0 { view.autoScales = false; view.scaleFactor = CGFloat(z) } else { view.autoScales = true }
        let targetPage: Int
        if let kp = keepPage {
            targetPage = min(max(0, kp), max(0, d.pageCount - 1))
        } else {
            targetPage = min(max(0, savedPage), max(0, d.pageCount - 1))
        }
        initialLoadedPage = targetPage
        currentPageIndex = targetPage
        UserDefaults.standard.set(targetPage, forKey: "page-" + session.doc.id.uuidString)
        if let p = d.safePage(targetPage) {
            view.go(to: p)
        }
        loading = false
        if variant == .bilingual { session.startBilingual(from: currentPageIndex) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let d = self.view.document else { return }
            if let initP = self.initialLoadedPage, let p = d.safePage(initP), self.view.currentPage != p {
                self.loading = true
                self.view.go(to: p)
                self.loading = false
            }
        }
        observeScroll()
        view.backgroundColor = MN.paperNS
    }

    func applyRemoteSyncedPage(_ i: Int) {
        guard let d = view.document, d.pageCount > 0 else { return }
        let clamped = min(max(0, i), d.pageCount - 1)
        guard let p = d.safePage(clamped) else { return }
        let wasLoading = loading
        loading = true
        initialLoadedPage = clamped
        currentPageIndex = clamped
        view.go(to: p)
        loading = wasLoading
    }

    func setVariant(_ v: Variant) {
        guard v != variant else { return }
        variant = v
        if let d = docId { UserDefaults.standard.set(v.rawValue, forKey: "variant-" + d.uuidString) }
        if let d = docId, let s = store.session(d) {
            load(session: s, variant: v)
            if v == .bilingual { s.startBilingual(from: currentPageIndex) }
        }
    }

    func unload() { view.document = nil; loadedKey = ""; closePopup() }

    func reloadAfterPDFEdit(session: DocSession, targetPage: Int) {
        closePopup()
        areaMode = false; eraseMode = false; truncateMode = false
        loading = true
        let d = session.document(variant)
        view.document = nil
        view.document = d
        loadedKey = session.doc.id.uuidString + variant.rawValue
        let z = UserDefaults.standard.double(forKey: "zoom")
        if z > 0 { view.autoScales = false; view.scaleFactor = CGFloat(z) } else { view.autoScales = true }
        let clamped = min(max(0, targetPage), max(0, d.pageCount - 1))
        initialLoadedPage = nil
        if let p = d.safePage(clamped) {
            view.go(to: p)
        }
        loading = false
        pageChanged()
        if variant == .bilingual { session.startBilingual(from: currentPageIndex) }
        view.setNeedsDisplay(view.bounds)
    }

    private var loading = false
    private var initialLoadedPage: Int? = nil
    private var programmaticScrollUntil = Date.distantPast
    @objc func pageChanged() {
        guard !loading, !restoring, Date() >= programmaticScrollUntil, let d = view.document, let p = view.currentPage else { return }
        if let fp = focusPage, Narrator.shared.state != .idle {
            if currentPageIndex != fp { currentPageIndex = fp }
            return
        }
        let i = d.index(for: p)
        guard i != NSNotFound, i >= 0 else { return }
        if i != currentPageIndex { currentPageIndex = i }
        if let id = docId {
            if let initP = initialLoadedPage {
                if i == initP {
                    if variant == .bilingual { store.sessions[id]?.prioritize(i) }
                    return
                }
                initialLoadedPage = nil
            }
            UserDefaults.standard.set(i, forKey: "page-" + id.uuidString)
            let total = store.sessions[id]?.pageCount ?? d.pageCount
            store.updateReadingProgress(docId: id, page: i, pageCount: total)
            if variant == .bilingual { store.sessions[id]?.prioritize(i) }
        }
    }

    // MARK: keeping the reading position while bilingual pages are swapped in

    /// what the reader is looking at: a point ~1/4 down the viewport, as (page, y in page) + its offset from the viewport top
    private struct ScrollAnchor { let index: Int; let pageY: CGFloat; let fraction: CGFloat; let x: CGFloat; let offset: CGFloat }

    private func captureAnchor() -> ScrollAnchor? {
        guard let doc = view.document, let dv = view.documentView, let clip = dv.enclosingScrollView?.contentView else { return nil }
        let vis = clip.bounds
        let off = min(160, vis.height * 0.25)
        let probe = NSPoint(x: vis.midX, y: dv.isFlipped ? vis.minY + off : vis.maxY - off)
        let pt = view.convert(probe, from: dv)
        guard let page = view.page(for: pt, nearest: true) else { return nil }
        let pp = view.convert(pt, to: page)
        let h = page.bounds(for: view.displayBox).height
        guard pp.isSane, h.isSane, vis.origin.isSane else { return nil }
        let y = min(max(pp.y, 0), h)
        return ScrollAnchor(index: doc.index(for: page), pageY: y, fraction: h > 0 ? y / h : 0, x: vis.minX, offset: off)
    }

    func debugTopPosition() -> String {
        guard let a = captureAnchor(), let page = view.document?.safePage(a.index) else { return "nil" }
        // text of the line at the viewport top (what the reader is looking at)
        let r = CGRect(x: 0, y: a.pageY - 12, width: page.bounds(for: .cropBox).width, height: 24)
        let t = (page.selection(for: r)?.string ?? "").replacingOccurrences(of: "\n", with: " ").prefix(40)
        return String(format: "page %d y %.0f/%.0f | ", a.index, a.pageY, page.bounds(for: .cropBox).height) + t
    }

    private func restore(_ a: ScrollAnchor, replaced: Int, oldIns: [[Double]] = [], newIns: [[Double]] = []) {
        guard let doc = view.document, let page = doc.safePage(a.index), let dv = view.documentView,
              let sv = dv.enclosingScrollView else { return }
        let h = page.bounds(for: view.displayBox).height
        var y = a.pageY
        if a.index == replaced {
            // map through the content: old layout → original page → new layout, so the line you were reading stays put
            let oldH = a.fraction > 0 ? (a.pageY / a.fraction).finiteOr(h) : h
            let tdOld = oldH - a.pageY
            let tdNew = DocSession.fromOriginal(DocSession.toOriginal(tdOld, oldIns), newIns)
            y = h - tdNew
        }
        let inView = view.convert(NSPoint(x: 0, y: y), from: page)
        let inDoc = dv.convert(inView, from: view)
        let visH = sv.contentView.bounds.height
        let originY = dv.isFlipped ? inDoc.y - a.offset : inDoc.y - visH + a.offset
        let target = NSPoint(x: a.x, y: originY)
        guard target.isSane else { return }
        sv.contentView.scroll(to: target)
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: batched, jitter-free page swaps
    private var pendingSwaps: [(DocSession, Int, () -> Void)] = []
    private var swapTimer: Timer?
    private var lastScroll = Date.distantPast

    func enqueueSwap(_ s: DocSession, page: Int, _ work: @escaping () -> Void) {
        let showing = s.doc.id == docId && variant == .bilingual && view.document === s.bilingual
        if !showing { work(); return }          // not on screen: swap immediately, nothing moves
        pendingSwaps.append((s, page, work))
        scheduleSwaps(after: 0.15)
    }

    private func scheduleSwaps(after t: TimeInterval) {
        guard swapTimer == nil else { return }
        swapTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.swapTimer = nil; self?.flushSwaps() }
        }
    }

    private func flushSwaps() {
        guard !pendingSwaps.isEmpty else { return }
        // never move the page under the reader's hand: wait until scrolling / mouse dragging stops
        if Date().timeIntervalSince(lastScroll) < 0.8 || NSEvent.pressedMouseButtons != 0 { scheduleSwaps(after: 0.5); return }
        let visible = Set(view.visiblePages.compactMap { view.document?.index(for: $0) })
        let cur = currentPageIndex
        // pages on screen get swapped right away (that's where the translation should appear);
        // off-screen pages are grouped so the document re-layouts at most once every ~2s
        let urgent = pendingSwaps.filter { visible.contains($0.1) || $0.1 == cur }
        let elapsed = Date().timeIntervalSince(lastFlush)
        let batch = (urgent.isEmpty && elapsed < 2.0) ? [] : pendingSwaps
        if batch.isEmpty { scheduleSwaps(after: 2.0 - elapsed); return }
        pendingSwaps.removeAll()
        lastFlush = Date()
        guard let s = batch.first?.0 else { return }
        // freeze the current pixels on top while the document re-lays out, then cross-fade — no flash, no jump
        let cover = snapshotCover()
        preservingPosition(of: s, variant: .bilingual, replacing: cur) {
            for (_, _, w) in batch { w() }
        }
        if let cover {
            // give PDFKit time to render the new tiles underneath, then fade the frozen frame away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSAnimationContext.runAnimationGroup({ c in c.duration = 0.25; cover.animator().alphaValue = 0 }, completionHandler: { cover.removeFromSuperview() })
            }
        }
    }

    private func snapshotCover() -> NSImageView? {
        guard let sup = view.superview, let win = view.window, win.isVisible, win.occlusionState.contains(.visible) else { return nil }
        // real on-screen pixels of our own window (PDF tiles are layers that cacheDisplay can't capture)
        let inWin = view.convert(view.bounds, to: nil)
        let onScreen = win.convertToScreen(inWin)
        guard let screenH = NSScreen.screens.first?.frame.height else { return nil }
        let cgRect = CGRect(x: onScreen.minX, y: screenH - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        guard let cg = CGWindowListCreateImage(cgRect, .optionIncludingWindow, CGWindowID(win.windowNumber), [.bestResolution, .boundsIgnoreFraming]) else { return nil }
        let iv = NSImageView(frame: view.frame)
        iv.image = NSImage(cgImage: cg, size: view.bounds.size)
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        sup.addSubview(iv, positioned: .above, relativeTo: view)
        return iv
    }
    private var lastFlush = Date.distantPast
    private var swappingAnchor: ScrollAnchor?

    /// the session rebuilt its bilingual PDF: show the new document in place of the old one
    func documentReplaced(_ session: DocSession) {
        guard session.doc.id == docId, variant == .bilingual else { return }
        let a = swappingAnchor ?? captureAnchor()
        let keepScale = view.autoScales ? nil : view.scaleFactor
        restoring = true
        view.document = session.bilingual
        if let k = keepScale { view.autoScales = false; view.scaleFactor = k }
        view.layoutDocumentView()
        if let a, swappingAnchor == nil { restore(a, replaced: -1) }   // outside a batched swap: keep position
        loadedKey = session.doc.id.uuidString + Variant.bilingual.rawValue
        restoring = false
    }
    private var holdUntil = Date.distantPast
    private var holdTarget: ScrollAnchor?
    private var userScrolledAt = Date.distantPast

    private func reassert() {
        guard focusPage == nil || Narrator.shared.state == .idle else { holdTarget = nil; return }
        guard let t = holdTarget, Date() < holdUntil, userScrolledAt < holdUntil.addingTimeInterval(-1.2) else { holdTarget = nil; return }
        restoring = true
        restore(t, replaced: -1)
        restoring = false
        updateAnchor()
        layoutFocus()
    }
    private var restoring = false

    /// Runs a page replacement without letting the visible content move.
    func preservingPosition(of session: DocSession, variant: Variant, replacing index: Int, _ work: () -> Void) {
        let showing = session.doc.id == docId && self.variant == variant && view.document === session.document(variant)
        guard showing, let a = captureAnchor() else { work(); return }
        swappingAnchor = a
        let sel = view.currentSelection
        restoring = true
        let oldIns = session.insertions[a.index] ?? []
        work()           // may replace view.document (see documentReplaced)
        swappingAnchor = nil
        view.layoutDocumentView()
        if let fp = focusPage, Narrator.shared.state != .idle {
            restoring = false
            highlightNarration(page: fp, quote: focusQuote)
            return
        }
        let newIns = session.insertions[a.index] ?? []
        restore(a, replaced: a.index, oldIns: oldIns, newIns: newIns)
        // PDFView restores its own saved destination asynchronously after page insert/remove; hold our position
        // against that for a moment (unless the user starts scrolling)
        if let page = view.document?.safePage(a.index) {
            let h = page.bounds(for: view.displayBox).height
            let oldH = a.fraction > 0 ? a.pageY / a.fraction : h
            let target = ScrollAnchor(index: a.index, pageY: h - DocSession.fromOriginal(DocSession.toOriginal(oldH - a.pageY, oldIns), newIns), fraction: 0, x: a.x, offset: a.offset)
            holdUntil = Date().addingTimeInterval(1.2)
            holdTarget = target
            for d in [0.0, 0.05, 0.15, 0.3, 0.5, 0.8, 1.1] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.reassert() }
            }
        }
        restoring = false
        if let sel, sel.pages.allSatisfy({ $0.document != nil }) { view.setCurrentSelection(sel, animate: false) }
        updateAnchor()
    }

    // MARK: mouse

    private func mouseMoved(_ e: NSEvent) {
        guard truncateMode, let cl = cutLineView else { return }
        let pt = view.convert(e.locationInWindow, from: nil)
        cl.cutY = pt.y
    }

    private func mouseDown(_ e: NSEvent) -> Bool {
        let pt = view.convert(e.locationInWindow, from: nil)
        if truncateMode {
            truncateMode = false
            truncateFromViewPoint(pt, below: true)
            return true
        }
        if areaMode || eraseMode {
            bandStart = pt
            let b = BandView(frame: NSRect(origin: pt, size: .zero))
            b.isErase = eraseMode
            view.addSubview(b); band = b
            return true
        }
        // click on an excerpt highlight → open its card (MarginNote behaviour)
        if !readingMode, e.clickCount == 1, !e.modifierFlags.contains(.shift), let id = cardAt(pt) {
            view.clearSelection()
            if popup == .card(id) { closePopup() } else { openCard(id) }
            return true
        }
        closePopup()
        return false
    }

    func cardAt(_ pt: NSPoint) -> UUID? {
        guard let page = view.page(for: pt, nearest: false) else { return nil }
        let pp = view.convert(pt, to: page)
        return (page.annotations.last(where: { ($0 as? CardAnnotation)?.cardId != nil && $0.bounds.insetBy(dx: -1, dy: -1).contains(pp) }) as? CardAnnotation)?.cardId
    }

    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        switch e.keyCode {
        case 49 where mods.isEmpty:    // space: page down (shift: up)
            scrollByScreen(e.modifierFlags.contains(.shift) ? -1 : 1); return true
        case 123 where mods.isEmpty: goToPage(max(0, currentPageIndex - 1)); return true   // ←
        case 124 where mods.isEmpty: goToPage(currentPageIndex + 1); return true           // →
        default:
            // 1–8: excerpt current selection with that colour (MarginNote shortcut style)
            if mods.isEmpty, hasSelection, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...highlightColors.count).contains(n) {
                makeCard(color: n - 1); return true
            }
            return false
        }
    }

    func scrollByScreen(_ dir: CGFloat) {
        guard let dv = view.documentView, let sv = dv.enclosingScrollView else { return }
        var o = sv.contentView.bounds.origin
        let delta = sv.contentView.bounds.height * 0.9 * dir
        o.y += dv.isFlipped ? delta : -delta
        guard o.isSane else { return }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; sv.contentView.animator().setBoundsOrigin(o) }
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func mouseDragged(_ e: NSEvent) -> Bool {
        guard (areaMode || eraseMode), let s = bandStart, let b = band else { return false }
        let pt = view.convert(e.locationInWindow, from: nil)
        b.frame = NSRect(x: min(s.x, pt.x), y: min(s.y, pt.y), width: abs(pt.x - s.x), height: abs(pt.y - s.y))
        return true
    }

    private func mouseUp(_ e: NSEvent) {
        if (areaMode || eraseMode), let b = band {
            let r = b.frame
            let wasErase = eraseMode
            b.removeFromSuperview(); band = nil; bandStart = nil
            if r.width > 8 && r.height > 8 {
                if wasErase { eraseRegionInView(viewRect: r) }
                else { makeAreaCard(viewRect: r) }
            }
            return
        }
        DispatchQueue.main.async { self.afterSelection() }
    }

    func simulateMouseUp() { DispatchQueue.main.async { self.afterSelection() } }

    private func afterSelection() {
        guard let sel = view.currentSelection, let s = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        selectionString = s
        if readingMode { return }      // ordinary selection: copy with ⌘C, gone on next click
        if autoExcerpt { makeCard(color: lastColor); return }
        guard let page = sel.pages.first, let d = view.document else { return }
        popupPage = d.index(for: page)
        popupRect = sel.bounds(for: page)
        popup = .selection
        updateAnchor()
    }

    @objc func viewMoved() {
        if focusView != nil, !restoring { layoutFocus() }
        if !restoring && holdTarget == nil { lastScroll = Date() }
        if popup != .none { updateAnchor() }
        let sp = view.scaleFactor * 100
        if abs(sp - scalePercent) > 0.5 { scalePercent = sp }
    }

    func updateAnchor() {
        guard let pi = popupPage, let page = view.document?.safePage(pi) else { anchor = nil; return }
        let r = view.convert(popupRect, from: page)
        let a = CGRect(x: r.minX, y: view.bounds.height - r.maxY, width: r.width, height: r.height)
        // hide when scrolled out of sight
        if a.maxY < 0 || a.minY > view.bounds.height { anchor = nil } else { anchor = a }
    }

    func openCard(_ id: UUID) {
        guard let c = store.card(id) else { return }
        store.selectedCardId = id
        if let node = store.currentNotebook?.root.nodeFor(card: id) { store.selectedNodeId = node.id }
        popupPage = c.page
        popupRect = c.rects.reduce(CGRect.null) { $0.union($1) }
        if popupRect.isNull { popupRect = .zero }
        popup = .card(id)
        updateAnchor()
    }

    func closePopup() {
        if popup != .none { popup = .none }
        anchor = nil
        popupPage = nil
    }

    @objc func selectionChanged() {
        let s = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasSelection = !s.isEmpty
        if s.isEmpty, popup == .selection { closePopup() }
    }

    func translateSelection(_ s: String) {
        guard s.count >= 2, s.count < 5000 else { return }
        store.selectionText = s
        store.selectionTranslation = ""
        store.selectionBusy = true
        Task {
            let t: String
            do { t = try await Translator.translateOne(s) } catch { t = "⚠️ " + error.localizedDescription }
            if self.store.selectionText == s { self.store.selectionTranslation = t; self.store.selectionBusy = false }
        }
    }

    func copySelection() {
        guard let s = view.currentSelection?.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        closePopup()
    }

    // MARK: actions
    func makeCard(color: Int? = nil) {
        guard let sel = view.currentSelection, let d = view.document, let docId = docId else { return }
        let text = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let color = color ?? lastColor
        lastColor = color
        var page: PDFPage?
        var rects: [CGRect] = []
        for line in sel.selectionsByLine() {
            guard let p = line.pages.first else { continue }
            if page == nil { page = p }
            if p != page { continue }
            let r = line.bounds(for: p)
            if r.width > 0 { rects.append(r) }
        }
        guard let p = page else { return }
        let card = Card(docId: docId, page: d.index(for: p), variant: variant, rects: rects, text: text, color: color)
        store.addCard(card)
        store.sessions[docId]?.refreshAnnotations(for: card)
        view.clearSelection()
        view.setNeedsDisplay(view.bounds)
        openCard(card.id)
    }

    /// rectangular "框选" excerpt: stores a picture of the region
    func makeAreaCard(viewRect r: NSRect) {
        guard let d = view.document, let docId = docId,
              let page = view.page(for: NSPoint(x: r.midX, y: r.midY), nearest: true) else { return }
        let pr = view.convert(r, to: page).intersection(page.bounds(for: view.displayBox))
        guard pr.width > 2, pr.height > 2 else { return }
        // text inside the region (if any) becomes the card text, the picture is kept as well
        let txt = (page.selection(for: pr)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var card = Card(docId: docId, page: d.index(for: page), variant: variant, rects: [pr], text: txt, color: lastColor)
        card.isImage = true
        if let png = renderRegion(page: page, rect: pr) { try? png.write(to: Paths.cardImage(card.id)) }
        store.addCard(card)
        store.sessions[docId]?.refreshAnnotations(for: card)
        areaMode = false
        openCard(card.id)
    }

    func renderRegion(page: PDFPage, rect: CGRect) -> Data? {
        let scale: CGFloat = 3
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        // draw the raw page content (no annotations) straight from CoreGraphics — no annotation churn
        if let cg = page.pageRef { ctx.drawPDFPage(cg) } else { page.draw(with: view.displayBox, to: ctx) }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    func jump(to c: Card) {
        guard let d = view.document, let p = d.safePage(c.page) else { return }
        let r = c.rects.reduce(CGRect.null) { $0.union($1) }
        view.go(to: CGRect(x: r.minX, y: r.maxY + 80, width: 1, height: 1), on: p)
        let flash = PDFAnnotation(bounds: r.insetBy(dx: -3, dy: -3), forType: .square, withProperties: nil)
        flash.color = NSColor.systemRed
        let b = PDFBorder(); b.lineWidth = 2; flash.border = b
        p.addAnnotation(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { p.removeAnnotation(flash) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.openCard(c.id) }
    }

    // MARK: narration focus box (AI 解读) — a breathing frame around the paragraph / figure being explained
    private var focusPage: Int?
    var focusedNarrationPage: Int? { focusPage }
    private var focusRect: CGRect = .zero          // page coordinates
    private var focusQuote: String?
    private var scrollTimer: Timer?

    func debugFocus() -> String {
        guard focusView != nil, let i = focusPage, let p = view.document?.safePage(i) else { return "none" }
        let r = focusRect
        let txt = (p.selection(for: r)?.string ?? "").replacingOccurrences(of: "\n", with: " ").prefix(70)
        let inView = view.convert(r, from: p)
        return String(format: "rect %.0f,%.0f %.0fx%.0f viewY %.0f-%.0f of %.0f | ", r.minX, r.minY, r.width, r.height, inView.minY, inView.maxY, view.bounds.height) + txt
    }

    func clearNarrationHighlight() {
        scrollTimer?.invalidate(); scrollTimer = nil
        focusView?.removeFromSuperview(); focusView = nil; focusPage = nil; focusQuote = nil
    }

    /// set by the narrator: the spoken segment talks about a figure/table ("图", "表", "横轴"…)
    var segmentMentionsFigure = false

    /// Fast single-page quote lookup that tolerates PDF line-wraps without scanning all pages of the book.
    private func findQuote(_ q: String, on page: PDFPage) -> PDFSelection? {
        if let raw = page.string, !raw.isEmpty {
            let ns = raw as NSString
            var candidates: [String] = [q]
            if q.count > 18 { candidates.append(String(q.prefix(18))) }
            if q.count > 10 { candidates.append(String(q.prefix(10))) }
            let words = q.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 4 { candidates.append(words.prefix(4).joined(separator: " ")) }
            if words.count >= 3 { candidates.append(words.prefix(3).joined(separator: " ")) }
            if words.count >= 2 { candidates.append(words.prefix(2).joined(separator: " ")) }
            for cand in candidates where cand.count >= 3 {
                let r = ns.range(of: cand, options: [.caseInsensitive, .diacriticInsensitive])
                if r.location != NSNotFound, let sel = page.selection(for: r), sel.bounds(for: page).width > 0 {
                    return sel
                }
                let escaped = cand.split(whereSeparator: { $0.isWhitespace })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[\\s\\-\\n\\r]+")
                if !escaped.isEmpty {
                    let rr = ns.range(of: escaped, options: [.regularExpression, .caseInsensitive])
                    if rr.location != NSNotFound, let sel = page.selection(for: rr), sel.bounds(for: page).width > 0 {
                        return sel
                    }
                }
            }
        }
        return nil
    }

    func highlightNarration(page i: Int, quote: String?) {
        guard let d = view.document, let shown = d.safePage(i), let docId = docId, let ses = store.sessions[docId],
              let orig = ses.original.safePage(i) else { return }
        focusQuote = quote
        // always locate on the ORIGINAL page (bilingual pages carry hidden duplicate text from their bands)
        var target: CGRect?
        if let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), q.count >= 3 {
            var found = findQuote(q, on: orig)
            if found == nil {
                found = ses.original.findString(q, withOptions: [.caseInsensitive]).first { $0.pages.contains(orig) }
            }
            if found == nil, q.count > 10 {
                found = ses.original.findString(String(q.prefix(10)), withOptions: [.caseInsensitive]).first { $0.pages.contains(orig) }
            }
            if let sel = found { target = blockRect(around: sel.bounds(for: orig), page: orig, isFigure: segmentMentionsFigure) }
        }
        let origBox = orig.bounds(for: .cropBox)
        target = target?.sanitized(in: origBox)
        // fallback: all text on the page. A page with no text (scans, figures) yields CGRect.null here,
        // whose inf origin turned into NaN after view.convert -> crash in setFrame. Sanitize, else no box.
        if target == nil { target = orig.selection(for: origBox)?.bounds(for: orig).insetBy(dx: -6, dy: -6).sanitized(in: origBox) }
        guard var r = target else { clearNarrationHighlight(); return }
        // map into the displayed page when it is a bilingual page (translations inserted below paragraphs)
        if shown !== orig, let ins = ses.insertions[i], !ins.isEmpty {
            let H0 = orig.bounds(for: .cropBox).maxY, H1 = shown.bounds(for: .cropBox).maxY
            let top = H1 - DocSession.fromOriginal(H0 - r.maxY, ins)
            let bottomTD = DocSession.fromOriginal(H0 - r.minY, ins)
            // include the translation block that directly follows this paragraph
            var extra: CGFloat = 0
            let cutAfter = ins.filter { $0.count >= 2 && CGFloat($0[0]) >= H0 - r.minY - 2 }.min { $0[0] < $1[0] }
            if let c = cutAfter, CGFloat(c[0]) - (H0 - r.minY) < 24 { extra = CGFloat(c[1]) + (CGFloat(c[0]) - (H0 - r.minY)) }
            r = CGRect(x: r.minX, y: H1 - bottomTD - extra, width: r.width, height: (H1 - bottomTD - extra < top) ? top - (H1 - bottomTD - extra) : r.height)
        }
        guard let safe = r.sanitized(in: shown.bounds(for: .cropBox)) else { clearNarrationHighlight(); return }
        r = safe
        focusPage = i; focusRect = r
        if currentPageIndex != i { currentPageIndex = i }
        installFocusLayer()
        layoutFocus(animated: true)
        centerSmoothly(r, on: shown)
    }

    /// expand a hit to its whole paragraph (same text block), or to the figure region above a caption
    private func blockRect(around hit: CGRect, page: PDFPage, isFigure: Bool) -> CGRect {
        let full = page.bounds(for: .cropBox)
        let lines = (page.selection(for: full)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        guard let start = lines.firstIndex(where: { $0.intersects(hit.insetBy(dx: -1, dy: -1)) }) else { return hit.insetBy(dx: -6, dy: -4) }
        let h = lines[start].height
        guard h.isSane, h > 0 else { return hit.insetBy(dx: -6, dy: -4) }
        // whole-line rects: PDFKit lines can be fragments (TOC entries, inline math) — widen to the column
        let colL = lines.filter { abs($0.midY - lines[start].midY) < h * 0.6 }.map { $0.minX }.min() ?? lines[start].minX
        let colR = lines.filter { abs($0.midY - lines[start].midY) < h * 0.6 }.map { $0.maxX }.max() ?? lines[start].maxX
        func sameBlock(_ a: CGRect, _ b: CGRect) -> Bool {
            let gap = abs(a.midY - b.midY)
            let ov = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            return gap < h * 1.9 && gap > 0.3 * h && ov > 0.15 * min(a.width, b.width) && abs(a.height - b.height) < h * 0.6
        }
        var r = lines[start]
        var k = start
        while k > 0, sameBlock(lines[k - 1], lines[k]) { k -= 1; r = r.union(lines[k]) }
        k = start
        while k + 1 < lines.count, sameBlock(lines[k + 1], lines[k]) { k += 1; r = r.union(lines[k]) }
        // the block is a caption ("Figure 2 | …"), or the segment talks about a figure: frame graphic + caption
        let blockText = (page.selection(for: r)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isCaption = blockText.range(of: "^(Figure|Fig\\.|Table)\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        var isFigure = isFigure || isCaption
        // a figure graphic is a large region with no body text; find the one nearest to this block
        if isFigure && !isCaption, let cap = lines.first(where: { (page.selection(for: $0)?.string ?? "").range(of: "^(Figure|Fig\\.)\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil }) {
            // use the caption block as anchor instead of the text paragraph
            r = cap
            isFigure = true
        }
        // never frame just a few words: at least the full line, and a sensible minimum size
        r = r.union(CGRect(x: colL, y: r.minY, width: colR - colL, height: r.height))
        if r.width < full.width * 0.45 {
            let cx = r.midX, w = full.width * 0.45
            r = CGRect(x: max(full.minX + 20, cx - w / 2), y: r.minY, width: w, height: r.height)
        }
        if r.height < h * 2.2 { r = r.insetBy(dx: 0, dy: -(h * 2.2 - r.height) / 2) }
        if isFigure {
            // the graphic sits above its caption: extend up over the non-text region
            // stop at the previous body-text line (wide); chart labels inside the graphic are narrow and ignored
            let bodyW = full.width * 0.55
            let above = lines.filter { $0.minY > r.maxY + 2 && $0.width > bodyW }.map { $0.minY }.min() ?? full.maxY - 30
            r = CGRect(x: min(r.minX, full.minX + 40), y: r.minY, width: max(r.width, full.width - 80), height: max(h, above - 4 - r.minY))
        }
        return r.insetBy(dx: -8, dy: -6)
    }

    // A transparent NSView in the PDF document view, positioned over the content; the breathing is a
    // Core Animation loop on its layer (runs on the render server — zero CPU, never re-renders the PDF).
    private var focusView: NSView?

    private func installFocusLayer() {
        guard let dv = view.documentView else { return }
        if let existing = focusView {
            if existing.superview !== dv { dv.addSubview(existing) }
            return
        }
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        guard let l = v.layer else { return }
        l.cornerRadius = 6
        l.borderWidth = 1.2
        l.borderColor = NSColor.systemPurple.withAlphaComponent(0.35).cgColor
        l.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.025).cgColor
        l.shadowColor = NSColor.systemPurple.cgColor
        l.shadowOffset = .zero
        l.shadowRadius = 6
        l.shadowOpacity = 0.0
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = NSColor.systemPurple.withAlphaComponent(0.15).cgColor
        border.toValue = NSColor.systemPurple.withAlphaComponent(0.5).cgColor
        let glow = CABasicAnimation(keyPath: "shadowOpacity"); glow.fromValue = 0.0; glow.toValue = 0.35
        let g = CAAnimationGroup(); g.animations = [border, glow]; g.duration = 1.4; g.autoreverses = true; g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(g, forKey: "breathe")
        dv.addSubview(v)
        focusView = v
    }

    func layoutFocus(animated: Bool = false) {
        guard let v = focusView, let i = focusPage, let page = view.document?.safePage(i), let dv = view.documentView else { return }
        guard focusRect.isSane else { v.isHidden = true; return }
        let inView = view.convert(focusRect, from: page)
        let f = dv.convert(inView, from: view)
        // page not laid out yet / degenerate conversion: never hand AppKit a NaN frame
        guard f.isSane else { v.isHidden = true; return }
        v.isHidden = false
        if animated {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; c.allowsImplicitAnimation = true; v.animator().frame = f }
        } else { v.frame = f }
    }

    /// Smoothly scroll so the top of `r` (page coords) aligns near the top of the reading viewport.
    func centerSmoothly(_ r: CGRect, on page: PDFPage) {
        guard r.isSane, let dv = view.documentView, let sv = dv.enclosingScrollView else { return }
        holdTarget = nil
        holdUntil = .distantPast
        scrollTimer?.invalidate()
        scrollTimer = nil

        let clip = sv.contentView
        let inView = view.convert(r, from: page)
        let inDoc = dv.convert(inView, from: view)
        guard inDoc.isSane, clip0Sane(clip.bounds) else { return }

        let visH = clip.bounds.height
        let topPad: CGFloat = 18
        let targetY = dv.isFlipped ? inDoc.minY - topPad : inDoc.maxY + topPad - visH
        // Allow scrolling below y=0 in unflipped documentView coords so paragraphs in the lower portion
        // of the last page (or a single-page PDF) can still move up to the top of the viewport.
        let minY = dv.isFlipped ? 0 : -visH * 0.78
        let maxY = dv.isFlipped ? max(0, dv.bounds.height - visH * 0.22) : max(0, dv.bounds.height - visH * 0.22)
        let endY = min(max(minY, targetY), maxY)
        let startY = clip.bounds.origin.y
        guard endY.isSane, startY.isSane else { return }

        programmaticScrollUntil = Date().addingTimeInterval(0.75)
        if abs(endY - startY) < 2 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: endY))
            sv.reflectScrolledClipView(clip)
            layoutFocus()
            return
        }

        restoring = true
        let steps = 16
        var step = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let dv = self.view.documentView, let sv = dv.enclosingScrollView else {
                    t.invalidate()
                    return
                }
                let clip = sv.contentView
                step += 1
                let progress = min(1.0, CGFloat(step) / CGFloat(steps))
                let eased = 1.0 - pow(1.0 - progress, 3)
                let curY = startY + (endY - startY) * eased
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: curY))
                sv.reflectScrolledClipView(clip)
                self.layoutFocus()
                if step >= steps {
                    t.invalidate()
                    self.scrollTimer = nil
                    self.restoring = false
                    if let fp = self.focusPage, self.currentPageIndex != fp {
                        self.currentPageIndex = fp
                    }
                    // Re-assert once more in case PDFKit performed an async tile/page layout pass
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self, self.scrollTimer == nil, let fp = self.focusPage,
                              let pg = self.view.document?.safePage(fp),
                              let dv = self.view.documentView, let sv = dv.enclosingScrollView else { return }
                        let clip = sv.contentView
                        let iv = self.view.convert(self.focusRect, from: pg)
                        let idoc = dv.convert(iv, from: self.view)
                        guard idoc.isSane, self.clip0Sane(clip.bounds) else { return }
                        let vh = clip.bounds.height
                        let ty = dv.isFlipped ? idoc.minY - topPad : idoc.maxY + topPad - vh
                        let ey = min(max(dv.isFlipped ? 0 : -vh * 0.78, ty), max(0, dv.bounds.height - vh * 0.22))
                        if abs(ey - clip.bounds.origin.y) > 4 {
                            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: ey))
                            sv.reflectScrolledClipView(clip)
                            self.layoutFocus()
                        }
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func clip0Sane(_ b: CGRect) -> Bool { b.origin.isSane && b.width.isSane && b.height.isSane && b.height > 0 }

    func goToPage(_ i: Int) {
        guard let d = view.document, d.pageCount > 0 else { return }
        let clamped = min(max(0, i), d.pageCount - 1)
        initialLoadedPage = nil
        if let p = d.safePage(clamped) {
            view.go(to: p)
            currentPageIndex = clamped
            if let id = docId {
                UserDefaults.standard.set(clamped, forKey: "page-" + id.uuidString)
                let total = store.sessions[id]?.pageCount ?? d.pageCount
                store.updateReadingProgress(docId: id, page: clamped, pageCount: total)
            }
        }
    }

    func zoom(_ f: CGFloat) {
        let a = captureAnchor()
        view.autoScales = false
        view.scaleFactor = max(0.25, min(5, view.scaleFactor * f))
        UserDefaults.standard.set(Double(view.scaleFactor), forKey: "zoom")
        if let a { restore(a, replaced: -1) }
        viewMoved()
    }
    func fitWidth() { view.autoScales = true; UserDefaults.standard.removeObject(forKey: "zoom"); DispatchQueue.main.async { self.viewMoved() } }

    // MARK: - PDF Editing Actions

    func truncateFromViewPoint(_ ptInView: NSPoint, below: Bool) {
        guard let d = view.document, let docId = docId, let ses = store.session(docId),
              let page = view.page(for: ptInView, nearest: true) else { return }
        let pageIndex = d.index(for: page)
        let ptInPage = view.convert(ptInView, to: page)
        let origY = PDFEditor.mapYToOriginal(session: ses, variant: variant, pageIndex: pageIndex, pageY: ptInPage.y)
        if below {
            PDFEditor.truncateFromHereToEnd(session: ses, pageIndex: pageIndex, origY: origY)
        } else {
            PDFEditor.truncateAboveHere(session: ses, pageIndex: pageIndex, origY: origY)
        }
    }

    func eraseRegionInView(viewRect r: NSRect) {
        defer { eraseMode = false }
        guard let d = view.document, let docId = docId, let ses = store.session(docId),
              let page = view.page(for: NSPoint(x: r.midX, y: r.midY), nearest: true) else { return }
        let pageIndex = d.index(for: page)
        let pr = view.convert(r, to: page).intersection(page.bounds(for: view.displayBox))
        guard pr.width > 4, pr.height > 4 else { return }
        let origRect = PDFEditor.mapRectToOriginal(session: ses, variant: variant, pageIndex: pageIndex, rect: pr)
        PDFEditor.eraseRegion(session: ses, pageIndex: pageIndex, origRect: origRect)
    }

    private func extendMenu(_ m: NSMenu, event: NSEvent) {
        contextMenuPointInView = view.convert(event.locationInWindow, from: nil)
        if hasSelection {
            m.insertItem(.separator(), at: 0)
            for (i, n) in highlightNames.enumerated().reversed() {
                let it = NSMenuItem(title: LF("摘录（%@）", "\(n)"), action: #selector(menuCard(_:)), keyEquivalent: "")
                it.target = self; it.tag = i
                it.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in highlightColors[i].setFill(); NSBezierPath(ovalIn: r).fill(); return true }
                m.insertItem(it, at: 0)
            }
            let t = NSMenuItem(title: L("翻译选中文本"), action: #selector(menuTranslate), keyEquivalent: "")
            t.target = self
            m.insertItem(t, at: 0)
        }
        guard let docId = docId, let ses = store.sessions[docId] else { return }
        m.addItem(.separator())
        let truncBelow = NSMenuItem(title: "✂️ " + L("从此处开始截断后面"), action: #selector(menuTruncateBelow), keyEquivalent: "")
        truncBelow.target = self
        m.addItem(truncBelow)

        let truncAbove = NSMenuItem(title: "✂️ " + L("从此处截断本页上方"), action: #selector(menuTruncateAbove), keyEquivalent: "")
        truncAbove.target = self
        m.addItem(truncAbove)

        let eraseIt = NSMenuItem(title: "🧽 " + L("框选擦除页面区域"), action: #selector(menuStartErase), keyEquivalent: "")
        eraseIt.target = self
        m.addItem(eraseIt)

        if ses.pageCount > 1 {
            let delPage = NSMenuItem(title: "🗑 " + LF("删除当前页 (p.%d)", currentPageIndex + 1), action: #selector(menuDeleteCurrentPage), keyEquivalent: "")
            delPage.target = self
            m.addItem(delPage)
            if currentPageIndex + 1 < ses.pageCount {
                let delAfter = NSMenuItem(title: L("删除当前页之后的所有页"), action: #selector(menuDeletePagesAfter), keyEquivalent: "")
                delAfter.target = self
                m.addItem(delAfter)
            }
            if currentPageIndex > 0 {
                let delBefore = NSMenuItem(title: L("删除当前页之前的所有页"), action: #selector(menuDeletePagesBefore), keyEquivalent: "")
                delBefore.target = self
                m.addItem(delBefore)
            }
        }
        if PDFEditor.hasBackup(docId) {
            let restoreIt = NSMenuItem(title: "↺ " + L("恢复原始未编辑 PDF"), action: #selector(menuRestorePDF), keyEquivalent: "")
            restoreIt.target = self
            m.addItem(restoreIt)
        }
    }
    @objc func menuCard(_ s: NSMenuItem) { makeCard(color: s.tag) }
    @objc func menuTranslate() {
        if let s = view.currentSelection?.string {
            selectionString = s.trimmingCharacters(in: .whitespacesAndNewlines)
            translateSelection(selectionString)
            if popup != .selection { afterSelection() }
        }
    }
    @objc func menuTruncateBelow() {
        guard let pt = contextMenuPointInView else { return }
        truncateFromViewPoint(pt, below: true)
    }
    @objc func menuTruncateAbove() {
        guard let pt = contextMenuPointInView else { return }
        truncateFromViewPoint(pt, below: false)
    }
    @objc func menuStartErase() { eraseMode = true }
    @objc func menuDeleteCurrentPage() {
        guard let docId = docId, let ses = store.session(docId) else { return }
        PDFEditor.deletePage(session: ses, pageIndex: currentPageIndex)
    }
    @objc func menuDeletePagesAfter() {
        guard let docId = docId, let ses = store.session(docId) else { return }
        PDFEditor.deletePagesAfter(session: ses, pageIndex: currentPageIndex)
    }
    @objc func menuDeletePagesBefore() {
        guard let docId = docId, let ses = store.session(docId) else { return }
        PDFEditor.deletePagesBefore(session: ses, pageIndex: currentPageIndex)
    }
    @objc func menuRestorePDF() {
        guard let docId = docId, let ses = store.session(docId) else { return }
        PDFEditor.restoreOriginal(session: ses)
    }
}

struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        rc.view.frame = box.bounds
        rc.view.autoresizingMask = [.width, .height]
        box.addSubview(rc.view)
        PageTint.apply(to: rc.view)
        return box
    }
    func updateNSView(_ v: NSView, context: Context) {
        PageTint.apply(to: rc.view)
        if let id = rc.docId, let s = store.session(id) {
            rc.load(session: s, variant: rc.variant)
            if let j = store.pendingJump, j.docId == id {
                DispatchQueue.main.async { rc.jump(to: j); store.pendingJump = nil }
            }
        } else { rc.unload() }
    }
}
#endif
