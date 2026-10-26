import Foundation
import SwiftUI
import PDFKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage
typealias NSSize = CGSize
typealias NSPoint = CGPoint
typealias NSRect = CGRect

extension UIColor {
    convenience init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: srgbRed, green: green, blue: blue, alpha: alpha)
    }

    convenience init(calibratedWhite: CGFloat, alpha: CGFloat) {
        self.init(white: calibratedWhite, alpha: alpha)
    }

    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor? {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        let f = min(max(fraction, 0), 1)
        return UIColor(
            red: r1 * (1 - f) + r2 * f,
            green: g1 * (1 - f) + g2 * f,
            blue: b1 * (1 - f) + b2 * f,
            alpha: a1 * (1 - f) + a2 * f
        )
    }
}

extension UIImage {
    convenience init?(contentsOf url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d)
    }
}

extension UIFontDescriptor.SymbolicTraits {
    static var bold: UIFontDescriptor.SymbolicTraits { .traitBold }
}

extension NSValue {
    convenience init(point: CGPoint) {
        self.init(cgPoint: point)
    }
    var pointValue: CGPoint { cgPointValue }
}

extension Color {
    init(nsColor: UIColor) {
        self.init(uiColor: nsColor)
    }
}

extension Image {
    init(nsImage: UIImage) {
        self.init(uiImage: nsImage)
    }
}
#endif

// MARK: - Cross-Platform Utilities

enum PlatformClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    static func string() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        return UIPasteboard.general.string
        #endif
    }
}

enum PlatformBrowser {
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}

enum PlatformPDF {
    static func thumbnailPNG(_ page: PDFPage, size: CGSize) -> Data? {
        let img = page.thumbnail(of: size, for: .cropBox)
        #if os(macOS)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #elseif os(iOS)
        return img.pngData()
        #endif
    }

    static func thumbnailJPEG(_ page: PDFPage, maxDimension: CGFloat = 1400, quality: CGFloat = 0.72) -> Data {
        let b = page.bounds(for: .cropBox)
        let scale = min(2.0, maxDimension / max(1, max(b.width, b.height)))
        let img = page.thumbnail(of: CGSize(width: b.width * scale, height: b.height * scale), for: .cropBox)
        #if os(macOS)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let j = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return Data() }
        return j
        #elseif os(iOS)
        return img.jpegData(compressionQuality: quality) ?? Data()
        #endif
    }

    static func thumbnailCGImage(_ page: PDFPage, size: CGSize, for box: PDFDisplayBox = .cropBox) -> CGImage? {
        let img = page.thumbnail(of: size, for: box)
        #if os(macOS)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif os(iOS)
        return img.cgImage
        #endif
    }
}

// MARK: - Shared PDF & Geometry Extensions

extension PDFDocument {
    /// bounds-checked page lookup (stale indices after page swaps / doc changes must not raise)
    func safePage(_ i: Int) -> PDFPage? { i >= 0 && i < pageCount ? page(at: i) : nil }
}

extension CGFloat {
    var isSane: Bool { isFinite && !isNaN }
    func finiteOr(_ d: CGFloat) -> CGFloat { isSane ? self : d }
}

extension CGPoint {
    var isSane: Bool { x.isSane && y.isSane && abs(x) < 1e7 && abs(y) < 1e7 }
}

extension CGRect {
    var isSane: Bool {
        !isNull && !isInfinite && origin.isSane && size.width.isSane && size.height.isSane
            && width > 0 && height > 0 && width < 1e7 && height < 1e7
    }
    func sanitized(in b: CGRect) -> CGRect? {
        guard isSane, b.isSane else { return nil }
        let r = standardized.intersection(b)
        return r.isSane ? r : nil
    }
}

#if os(iOS)
// MARK: - iOS ReaderController & DocWindows Bridge

@MainActor
final class ReaderController: NSObject, ObservableObject {
    static let shared = ReaderController()

    let view = PDFView()
    @Published var docId: UUID?
    @Published var variant: Variant = .original
    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0
    @Published var selectionText: String = ""
    @Published var selectionRects: [CGRect] = []
    @Published var selectionPage: Int = 0
    @Published var narrationQuote: String?
    var segmentMentionsFigure = false
    private var narrationAnnotations: [PDFAnnotation] = []
    private var focusPage: Int?
    var focusedNarrationPage: Int? { focusPage }
    private var focusRect: CGRect = .zero
    private var focusView: UIView?
    private var loading = false
    private var pendingInitialPage: Int? = nil
    private var initialLoadedPage: Int? = nil
    private var programmaticScrollUntil = Date.distantPast

    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .PDFViewSelectionChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged),
            name: .PDFViewScaleChanged,
            object: view
        )
    }

    @objc private func scaleChanged() {
        layoutFocus(animated: false)
    }

    func bind(docId id: UUID) {
        guard let ses = Store.shared.session(id) else { return }
        // Read saved page BEFORE mutating docId or view.document so PDFViewPageChanged for page 0 cannot overwrite it
        let savedPage = Store.shared.doc(id)?.resolvedReadPage ?? 0
        loading = true
        if docId != id {
            clearNarrationHighlight()
            docId = id
            let savedVar = Variant(rawValue: UserDefaults.standard.string(forKey: "variant-" + id.uuidString) ?? "") ?? Store.shared.variant
            variant = savedVar
        }
        let targetDoc = ses.document(variant)
        pageCount = ses.pageCount
        let clamped = min(max(0, savedPage), max(0, pageCount - 1))
        currentPageIndex = clamped
        pendingInitialPage = clamped
        initialLoadedPage = clamped
        if view.document !== targetDoc {
            view.document = targetDoc
            view.autoScales = true
        }
        if let pg = targetDoc.safePage(clamped) {
            view.go(to: pg)
        }
        if variant == .bilingual {
            ses.startBilingual(from: clamped)
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingInitialPageIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.applyPendingInitialPageIfNeeded()
            self.loading = false
        }
    }

    func applyRemoteSyncedPage(_ i: Int) {
        guard let doc = view.document, doc.pageCount > 0 else { return }
        let clamped = min(max(0, i), doc.pageCount - 1)
        guard let pg = doc.safePage(clamped) else { return }
        let wasLoading = loading
        loading = true
        pendingInitialPage = clamped
        initialLoadedPage = clamped
        currentPageIndex = clamped
        view.go(to: pg)
        loading = wasLoading
    }

    func applyPendingInitialPageIfNeeded() {
        guard let target = pendingInitialPage, let doc = view.document else { return }
        let clamped = min(max(0, target), max(0, doc.pageCount - 1))
        if let pg = doc.safePage(clamped) {
            let curIdx = view.currentPage.map { doc.index(for: $0) } ?? NSNotFound
            if curIdx != clamped {
                let wasLoading = loading
                loading = true
                view.go(to: pg)
                loading = wasLoading
            }
            if currentPageIndex != clamped {
                currentPageIndex = clamped
            }
        }
        if view.bounds.width > 10 && view.bounds.height > 10 {
            pendingInitialPage = nil
            layoutFocus(animated: false)
        }
    }

    @discardableResult
    func syncCurrentPageFromView() -> Int {
        if !loading, pendingInitialPage == nil, let doc = view.document, let cur = view.currentPage {
            let idx = doc.index(for: cur)
            if idx != NSNotFound && idx >= 0 && idx < doc.pageCount {
                if currentPageIndex != idx {
                    currentPageIndex = idx
                }
                return idx
            }
        }
        return currentPageIndex
    }

    @objc private func pageChanged() {
        guard !loading, pendingInitialPage == nil, let doc = view.document, let cur = view.currentPage else { return }
        layoutFocus(animated: false)
        if Date() < programmaticScrollUntil, let fp = focusPage {
            if currentPageIndex != fp { currentPageIndex = fp }
            return
        }
        let idx = doc.index(for: cur)
        guard idx != NSNotFound, idx >= 0 else { return }
        if currentPageIndex != idx {
            currentPageIndex = idx
        }
        if let id = docId {
            if let initP = initialLoadedPage {
                if idx == initP {
                    if variant == .bilingual, let ses = Store.shared.session(id) {
                        ses.prioritize(idx)
                    }
                    return
                }
                initialLoadedPage = nil
            }
            UserDefaults.standard.set(idx, forKey: "page-" + id.uuidString)
            Store.shared.updateReadingProgress(docId: id, page: idx, pageCount: max(1, doc.pageCount))
            if variant == .bilingual, let ses = Store.shared.session(id) {
                ses.prioritize(idx)
            }
        }
    }

    @objc private func selectionChanged() {
        guard let sel = view.currentSelection,
              let raw = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let page = sel.pages.first,
              let doc = view.document else {
            selectionText = ""
            selectionRects = []
            return
        }
        let idx = doc.index(for: page)
        selectionPage = idx == NSNotFound ? currentPageIndex : idx
        selectionText = raw
        let lineSelections = sel.selectionsByLine()
        if lineSelections.isEmpty {
            selectionRects = [sel.bounds(for: page)]
        } else {
            selectionRects = lineSelections.map { $0.bounds(for: page) }
        }
    }

    func setVariant(_ v: Variant) {
        guard let id = docId, let ses = Store.shared.session(id) else {
            variant = v
            return
        }
        let curPage = currentPageIndex
        let activeFocusPage = focusPage
        let activeQuote = narrationQuote
        loading = true
        variant = v
        UserDefaults.standard.set(v.rawValue, forKey: "variant-" + id.uuidString)
        let targetDoc = ses.document(v)
        view.document = targetDoc
        view.autoScales = true
        if let pg = targetDoc.safePage(curPage) {
            view.go(to: pg)
        }
        currentPageIndex = curPage
        loading = false
        if v == .bilingual {
            ses.startBilingual(from: curPage)
        }
        if let fp = activeFocusPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.highlightNarration(page: fp, quote: activeQuote)
            }
        }
    }

    func goToPage(_ i: Int) {
        guard let doc = view.document else { return }
        let clamped = min(max(0, i), max(0, doc.pageCount - 1))
        pendingInitialPage = nil
        initialLoadedPage = nil
        if let pg = doc.safePage(clamped) {
            let wasLoading = loading
            loading = true
            view.go(to: pg)
            currentPageIndex = clamped
            loading = wasLoading
            if let id = docId {
                UserDefaults.standard.set(clamped, forKey: "page-" + id.uuidString)
                Store.shared.updateReadingProgress(docId: id, page: clamped, pageCount: doc.pageCount)
            }
        }
    }

    func jump(to card: Card) {
        if docId != card.docId {
            bind(docId: card.docId)
        }
        if variant != card.variant {
            setVariant(card.variant)
        }
        goToPage(card.page)
        if let pg = view.document?.safePage(card.page), let r = card.rects.first {
            view.go(to: r, on: pg)
        }
    }

    @discardableResult
    func excerptSelection(color: Int = 0) -> Card? {
        guard let id = docId, !selectionText.isEmpty, !selectionRects.isEmpty else { return nil }
        let c = Card(docId: id, page: selectionPage, variant: variant, rects: selectionRects, text: selectionText, color: color)
        Store.shared.addCard(c)
        Store.shared.session(id)?.refreshAnnotations(for: c)
        view.clearSelection()
        selectionText = ""
        selectionRects = []
        return c
    }

    func enqueueSwap(_ s: DocSession, page: Int, _ w: @escaping () -> Void) {
        w()
    }

    func documentReplaced(_ s: DocSession) {
        guard docId == s.doc.id, variant == .bilingual else { return }
        let curPage = currentPageIndex
        let activeFocusPage = focusPage
        let activeQuote = narrationQuote
        let wasLoading = loading
        loading = true
        view.document = s.bilingual
        view.autoScales = true
        if let pg = s.bilingual.safePage(curPage) {
            view.go(to: pg)
        }
        currentPageIndex = curPage
        loading = wasLoading
        if let fp = activeFocusPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.highlightNarration(page: fp, quote: activeQuote)
            }
        }
    }

    func reloadAfterPDFEdit(session: DocSession, targetPage: Int) {
        guard docId == session.doc.id else { return }
        let d = session.document(variant)
        loading = true
        view.document = d
        pageCount = session.pageCount
        loading = false
        goToPage(targetPage)
    }

    func highlightNarration(page i: Int, quote: String?) {
        clearNarrationAnnotationsOnly()
        narrationQuote = quote
        guard let d = view.document,
              let shown = d.safePage(i),
              let id = docId,
              let ses = Store.shared.session(id),
              let orig = ses.original.safePage(i) else {
            clearNarrationHighlight()
            return
        }

        // Locate quote on the ORIGINAL page (matching macOS Reader.swift)
        var target: CGRect?
        if let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), q.count >= 3 {
            let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var found = ses.original.findString(q, withOptions: opts).first { $0.pages.contains(orig) }
            if found == nil, q.count > 10 {
                found = ses.original.findString(String(q.prefix(10)), withOptions: opts).first { $0.pages.contains(orig) }
            }
            if found == nil {
                let firstClause = q.split(whereSeparator: { ".,;:!?，。；：！？\n—–-()（）\"'“”".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { $0.count >= 4 }
                if let fc = firstClause {
                    found = ses.original.findString(String(fc.prefix(14)), withOptions: opts).first { $0.pages.contains(orig) }
                }
            }
            if let sel = found {
                target = blockRect(around: sel.bounds(for: orig), page: orig, isFigure: segmentMentionsFigure)
            }
        }
        let origBox = orig.bounds(for: .cropBox)
        target = target?.sanitized(in: origBox)
        if target == nil {
            target = orig.selection(for: origBox)?.bounds(for: orig).insetBy(dx: -6, dy: -6).sanitized(in: origBox)
        }
        guard var r = target else {
            clearNarrationHighlight()
            return
        }

        // Map into displayed page when viewing bilingual mode
        if shown !== orig, let ins = ses.insertions[i], !ins.isEmpty {
            let H0 = orig.bounds(for: .cropBox).maxY, H1 = shown.bounds(for: .cropBox).maxY
            let top = H1 - DocSession.fromOriginal(H0 - r.maxY, ins)
            let bottomTD = DocSession.fromOriginal(H0 - r.minY, ins)
            var extra: CGFloat = 0
            let cutAfter = ins.filter { $0.count >= 2 && CGFloat($0[0]) >= H0 - r.minY - 2 }.min { $0[0] < $1[0] }
            if let c = cutAfter, CGFloat(c[0]) - (H0 - r.minY) < 24 {
                extra = CGFloat(c[1]) + (CGFloat(c[0]) - (H0 - r.minY))
            }
            r = CGRect(
                x: r.minX,
                y: H1 - bottomTD - extra,
                width: r.width,
                height: (H1 - bottomTD - extra < top) ? top - (H1 - bottomTD - extra) : r.height
            )
        }
        guard let safe = r.sanitized(in: shown.bounds(for: .cropBox)) else {
            clearNarrationHighlight()
            return
        }
        r = safe
        focusPage = i
        focusRect = r

        // 1. Add a crisp page-locked PDFAnnotation frame so pinch-zoom and scrolling stay 100% locked
        let ann = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        ann.color = UIColor.systemPurple.withAlphaComponent(0.65)
        ann.interiorColor = UIColor.systemPurple.withAlphaComponent(0.06)
        let border = PDFBorder()
        border.lineWidth = 1.6
        ann.border = border
        shown.addAnnotation(ann)
        narrationAnnotations.append(ann)

        // 2. Also install the breathing focus layer on documentView and smoothly scroll the paragraph into view
        installFocusLayer()
        layoutFocus(animated: true)
        centerSmoothly(r, on: shown)
    }

    private func blockRect(around hit: CGRect, page: PDFPage, isFigure: Bool) -> CGRect {
        let full = page.bounds(for: .cropBox)
        let lines = (page.selection(for: full)?.selectionsByLine() ?? [])
            .map { $0.bounds(for: page) }
            .filter { $0.width > 0 && $0.height > 0 }
        guard let start = lines.firstIndex(where: { $0.intersects(hit.insetBy(dx: -1, dy: -1)) }) else {
            return hit.insetBy(dx: -6, dy: -4)
        }
        let h = lines[start].height
        guard h.isSane, h > 0 else { return hit.insetBy(dx: -6, dy: -4) }
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
        let blockText = (page.selection(for: r)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isCaption = blockText.range(of: "^(Figure|Fig\\.|Table)\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        var isFig = isFigure || isCaption
        if isFig && !isCaption,
           let cap = lines.first(where: { (page.selection(for: $0)?.string ?? "").range(of: "^(Figure|Fig\\.)\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil }) {
            r = cap
            isFig = true
        }
        r = r.union(CGRect(x: colL, y: r.minY, width: colR - colL, height: r.height))
        if r.width < full.width * 0.45 {
            let cx = r.midX, w = full.width * 0.45
            r = CGRect(x: max(full.minX + 20, cx - w / 2), y: r.minY, width: w, height: r.height)
        }
        if r.height < h * 2.2 {
            r = r.insetBy(dx: 0, dy: -(h * 2.2 - r.height) / 2)
        }
        if isFig {
            let bodyW = full.width * 0.55
            let above = lines.filter { $0.minY > r.maxY + 2 && $0.width > bodyW }.map { $0.minY }.min() ?? full.maxY - 30
            r = CGRect(x: min(r.minX, full.minX + 40), y: r.minY, width: max(r.width, full.width - 80), height: max(h, above - 4 - r.minY))
        }
        return r.insetBy(dx: -8, dy: -6)
    }

    private func installFocusLayer() {
        guard let dv = view.documentView else { return }
        if let existing = focusView, existing.superview === dv { return }
        focusView?.removeFromSuperview()
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        let l = v.layer
        l.cornerRadius = 6
        l.borderWidth = 1.6
        l.borderColor = UIColor.systemPurple.withAlphaComponent(0.55).cgColor
        l.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.035).cgColor
        l.shadowColor = UIColor.systemPurple.cgColor
        l.shadowOffset = .zero
        l.shadowRadius = 6
        l.shadowOpacity = 0.0
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = UIColor.systemPurple.withAlphaComponent(0.22).cgColor
        border.toValue = UIColor.systemPurple.withAlphaComponent(0.70).cgColor
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.0
        glow.toValue = 0.35
        let g = CAAnimationGroup()
        g.animations = [border, glow]
        g.duration = 1.4
        g.autoreverses = true
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(g, forKey: "breathe")
        dv.addSubview(v)
        focusView = v
    }

    func layoutFocus(animated: Bool = false) {
        guard let v = focusView,
              let i = focusPage,
              let page = view.document?.safePage(i),
              let dv = view.documentView else { return }
        guard focusRect.isSane else { v.isHidden = true; return }
        let inView = view.convert(focusRect, from: page)
        let f = dv.convert(inView, from: view)
        guard f.isSane else { v.isHidden = true; return }
        v.isHidden = false
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                v.frame = f
            }
        } else {
            v.frame = f
        }
    }

    private func findScrollView(in root: UIView) -> UIScrollView? {
        var anc = view.documentView?.superview
        while let cur = anc {
            if let sv = cur as? UIScrollView { return sv }
            anc = cur.superview
        }
        if let sv = root as? UIScrollView { return sv }
        for sub in root.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private func centerSmoothly(_ r: CGRect, on page: PDFPage) {
        scrollRectToTop(r, on: page, animated: true)
        // Re-assert after PDFKit finishes any pending page/bilingual layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let fp = self.focusPage, let shown = self.view.document?.safePage(fp) else { return }
            self.layoutFocus(animated: false)
            self.scrollRectToTop(self.focusRect, on: shown, animated: true)
        }
    }

    private func scrollRectToTop(_ r: CGRect, on page: PDFPage, animated: Bool) {
        view.layoutDocumentView()
        guard r.isSane, let sv = findScrollView(in: view), sv.bounds.height > 40 else { return }
        // Ensure sufficient bottom scroll headroom so even paragraphs near the bottom of a page
        // can be scrolled all the way up to the top of the screen above the AI narrator card.
        let neededBottomInset = max(320, sv.bounds.height * 0.72)
        if sv.contentInset.bottom < neededBottomInset {
            var inset = sv.contentInset
            inset.bottom = neededBottomInset
            sv.contentInset = inset
        }
        let inView = view.convert(r, from: page)
        guard inView.isSane else { return }
        // Place the top of the framed paragraph near the top of the visible reading area (14pt margin)
        let topPad: CGFloat = 14
        let deltaY = inView.minY - topPad
        let targetY = sv.contentOffset.y + deltaY
        let minY = -sv.adjustedContentInset.top
        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let clampedY = min(max(minY, targetY), maxY)
        if let fp = focusPage, currentPageIndex != fp {
            currentPageIndex = fp
        }
        guard clampedY.isSane, abs(clampedY - sv.contentOffset.y) > 4 else { return }
        programmaticScrollUntil = Date().addingTimeInterval(0.65)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: clampedY), animated: animated)
    }

    private func clearNarrationAnnotationsOnly() {
        for ann in narrationAnnotations {
            ann.page?.removeAnnotation(ann)
        }
        narrationAnnotations.removeAll()
    }

    func clearNarrationHighlight() {
        narrationQuote = nil
        focusPage = nil
        focusRect = .zero
        focusView?.removeFromSuperview()
        focusView = nil
        clearNarrationAnnotationsOnly()
    }
}

@MainActor
final class DocWindows: ObservableObject {
    static let shared = DocWindows()

    struct WindowStub {
        var title: String = ""
        func makeKeyAndOrderFront(_ sender: Any?) {}
    }

    final class Entry {
        let docId: UUID
        var window = WindowStub()
        let reader: ReaderController
        init(docId: UUID, reader: ReaderController) {
            self.docId = docId
            self.reader = reader
        }
    }

    @Published var entries: [UUID: Entry] = [:]
    @Published var activeDocId: UUID?
    var active: Entry? { activeDocId.flatMap { entries[$0] } }

    func open(_ docId: UUID, notebook: UUID? = nil, jump: Card? = nil) {
        if let nb = notebook {
            Store.shared.currentNotebookId = nb
        }
        Store.shared.openDoc(docId)
        let rc = ReaderController.shared
        rc.bind(docId: docId)
        let entry = Entry(docId: docId, reader: rc)
        entry.window.title = Store.shared.doc(docId)?.title ?? ""
        entries[docId] = entry
        activeDocId = docId
        if let jump {
            rc.jump(to: jump)
        }
    }

    func close(_ docId: UUID) {
        entries.removeValue(forKey: docId)
        if activeDocId == docId {
            activeDocId = nil
        }
    }
}
#endif
