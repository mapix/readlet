import XCTest
import PDFKit
@testable import Readlet

@MainActor
final class NewFeaturesTests: XCTestCase {

    // MARK: - 1. Document Tags & Reading Progress Tests

    func testDocStatusTagAndCustomTags() {
        var doc = Doc(
            id: UUID(),
            title: "Test Paper",
            added: Date(),
            tags: ["TODO", "AI", "Agents"],
            pageCount: 10,
            readPage: 0
        )
        XCTAssertEqual(doc.statusTag, DocStatusTag.todo)
        XCTAssertEqual(doc.customTags, ["AI", "Agents"])
        XCTAssertEqual(doc.progressPercent, 10) // page 0 of 10 -> 1/10 = 10%

        // Update readPage to 4 (page 5 of 10 -> 50%)
        doc.readPage = 4
        XCTAssertEqual(doc.progressPercent, 50)
        XCTAssertEqual(doc.progressFraction, 0.5, accuracy: 0.001)

        // Update readPage to last page (page 10 of 10 -> 100%)
        doc.readPage = 9
        XCTAssertEqual(doc.progressPercent, 100)
        XCTAssertEqual(doc.progressFraction, 1.0, accuracy: 0.001)
    }

    func testDocBackwardCompatibleDecoding() throws {
        // Simulate legacy JSON without tags, pageCount, or readPage
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "title": "Legacy Document",
            "added": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Doc.self, from: legacyJSON)
        XCTAssertEqual(decoded.title, "Legacy Document")
        XCTAssertEqual(decoded.tags, [])
        XCTAssertNil(decoded.pageCount)
        XCTAssertNil(decoded.readPage)
        XCTAssertNil(decoded.statusTag)
        XCTAssertEqual(decoded.progressPercent, 0)
    }

    func testStoreTagOperationsAndProgressAutoStatus() {
        let store = Store.shared
        let docId = UUID()
        let initialDoc = Doc(
            id: docId,
            title: "Tag Test Doc",
            added: Date(),
            tags: [],
            pageCount: 5,
            readPage: nil
        )
        store.lib.docs.append(initialDoc)
        defer {
            store.lib.docs.removeAll { $0.id == docId }
            store.saveNow()
        }

        // Set status tag to TODO
        store.setStatusTag(docId, .todo)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.todo)

        // Add custom tags
        store.addTag(docId, "LLM")
        store.addTag(docId, "Paper")
        XCTAssertEqual(store.doc(docId)?.customTags, ["LLM", "Paper"])

        // Reading middle page automatically transitions TODO -> DOING
        store.updateReadingProgress(docId: docId, page: 2, pageCount: 5)
        XCTAssertEqual(store.doc(docId)?.readPage, 2)
        XCTAssertEqual(store.doc(docId)?.progressPercent, 60)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.doing)

        // Cycle status tag: DOING -> DONE -> TODO -> DOING
        store.cycleStatusTag(docId)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.done)
        XCTAssertEqual(store.doc(docId)?.progressPercent, 100)

        store.cycleStatusTag(docId)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.todo)

        // Toggle tag removes status tag when matching
        store.toggleTag(docId, "TODO")
        XCTAssertNil(store.doc(docId)?.statusTag)
    }

    // MARK: - 2. PDFEditor Tests (Truncate, Erase, Delete, Backup & Restore)

    private func makeSamplePDF(pageCount: Int, pageSize: CGSize = CGSize(width: 400, height: 600)) -> PDFDocument {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("Failed to create PDF context")
        }
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)
            let str = "Page \(i + 1) Top Content\n\nMiddle Content\n\nBottom Footer Noise" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(in: CGRect(x: 40, y: 100, width: 320, height: 440), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: pdfData as Data)!
    }

    func testPDFEditorTruncateEraseDeleteAndRestore() throws {
        let docId = UUID()
        let dir = Paths.docDir(docId)
        defer {
            try? FileManager.default.removeItem(at: dir)
            Store.shared.lib.docs.removeAll { $0.id == docId }
            Store.shared.lib.cards.removeAll { $0.docId == docId }
            Store.shared.saveNow()
        }

        let pdf = makeSamplePDF(pageCount: 4, pageSize: CGSize(width: 400, height: 600))
        XCTAssertTrue(pdf.write(to: Paths.pdf(docId)))

        let docModel = Doc(id: docId, title: "Editable PDF", added: Date(), pageCount: 4)
        Store.shared.lib.docs.append(docModel)
        guard let session = DocSession(doc: docModel) else {
            XCTFail("Failed to create DocSession")
            return
        }

        XCTAssertEqual(session.original.pageCount, 4)
        XCTAssertFalse(PDFEditor.hasBackup(docId))

        // 1. Erase a rectangular region on page 1
        let erased = PDFEditor.eraseRegion(session: session, pageIndex: 0, origRect: CGRect(x: 30, y: 80, width: 200, height: 60))
        XCTAssertTrue(erased)
        XCTAssertTrue(PDFEditor.hasBackup(docId))
        XCTAssertEqual(session.original.pageCount, 4)

        // 2. Truncate above y=450 on page 1 (keeps [0, 450] -> height becomes 450pt)
        let truncAbove = PDFEditor.truncateAboveHere(session: session, pageIndex: 0, origY: 450)
        XCTAssertTrue(truncAbove)
        let p0BoundsAfterAbove = session.original.page(at: 0)!.bounds(for: PDFDisplayBox.cropBox)
        XCTAssertEqual(p0BoundsAfterAbove.height, 450, accuracy: 1.0)

        // 3. Truncate from y=200 on page 2 (index 1) to the end of the document
        // Page count should drop from 4 to 2, and page 2 height should become 600 - 200 = 400pt
        let truncToEnd = PDFEditor.truncateFromHereToEnd(session: session, pageIndex: 1, origY: 200)
        XCTAssertTrue(truncToEnd)
        XCTAssertEqual(session.original.pageCount, 2)
        let p1Bounds = session.original.page(at: 1)!.bounds(for: PDFDisplayBox.cropBox)
        XCTAssertEqual(p1Bounds.height, 400, accuracy: 1.0)
        XCTAssertEqual(Store.shared.doc(docId)?.pageCount, 2)

        // 4. Delete page 0 -> leaves 1 page
        let deleted = PDFEditor.deletePage(session: session, pageIndex: 0)
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.original.pageCount, 1)

        // 5. Restore original untouched PDF from backup
        let restored = PDFEditor.restoreOriginal(session: session)
        XCTAssertTrue(restored)
        XCTAssertFalse(PDFEditor.hasBackup(docId))
        XCTAssertEqual(session.original.pageCount, 4)
        XCTAssertEqual(session.original.page(at: 0)!.bounds(for: PDFDisplayBox.cropBox).height, 600, accuracy: 1.0)
        XCTAssertEqual(Store.shared.doc(docId)?.pageCount, 4)
    }

    // MARK: - 3. UpdateChecker Tests

    func testUpdateCheckerVersionComparisonAndDecoding() throws {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))

        let json = """
        {"version":"1.0.1","file":"Readlet-1.0.1.zip","size":"3.2 MB","sha256":"abc12345","notes":"Bug fixes"}
        """.data(using: .utf8)!
        let rel = try JSONDecoder().decode(UpdateChecker.Release.self, from: json)
        XCTAssertEqual(rel.version, "1.0.1")
        XCTAssertEqual(rel.file, "Readlet-1.0.1.zip")
        XCTAssertEqual(rel.size, "3.2 MB")
    }

    // MARK: - 4. iCloud Multi-Device Sync (Mac <-> iPhone) Merge Tests

    func testCloudSyncMergeLibrariesAndTombstones() {
        let docId1 = UUID()
        let docId2 = UUID()
        let deletedDocId = UUID()
        let now = Date()

        // Mac library: doc1 at page 2 (TODO, tag "AI"), plus deletedDocId still present locally
        let macDoc1 = Doc(
            id: docId1,
            title: "Attention Is All You Need",
            added: now.addingTimeInterval(-3600),
            tags: ["TODO", "AI"],
            pageCount: 15,
            readPage: 2,
            updatedAt: now.addingTimeInterval(-600)
        )
        let macDeletedDoc = Doc(
            id: deletedDocId,
            title: "Old Draft",
            added: now.addingTimeInterval(-7200),
            pageCount: 5
        )

        var macCard = Card(
            docId: docId1,
            page: 2,
            variant: .original,
            rects: [CGRect(x: 10, y: 10, width: 100, height: 20)],
            text: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
            color: 0
        )
        macCard.comments = ["Mac note"]
        macCard.updatedAt = now.addingTimeInterval(-500)

        let nbId = UUID()
        let rootId = UUID()
        let macChild = MindNode(title: "Mac Topic")
        let macNotebook = Notebook(id: nbId, name: "Transformers", docIds: [docId1], root: MindNode(id: rootId, title: "Root", children: [macChild]))

        let macLib = Library(docs: [macDoc1, macDeletedDoc], notebooks: [macNotebook], cards: [macCard], links: [])

        // iPhone library: user read doc1 up to page 9, changed status to DOING, added tag "DeepLearning", translated card, and imported doc2
        let iphoneDoc1 = Doc(
            id: docId1,
            title: "Attention Is All You Need",
            added: now.addingTimeInterval(-3600),
            tags: ["DOING", "DeepLearning"],
            pageCount: 15,
            readPage: 9,
            updatedAt: now
        )
        let iphoneDoc2 = Doc(
            id: docId2,
            title: "DeepSeek-R1 Technical Report",
            added: now.addingTimeInterval(-100),
            tags: ["TODO"],
            pageCount: 22
        )
        var iphoneCard = macCard
        iphoneCard.translation = "主流序列转导模型基于复杂的循环或卷积神经网络。"
        iphoneCard.comments = ["iPhone note"]
        iphoneCard.color = 2
        iphoneCard.updatedAt = now

        let iphoneChild = MindNode(title: "iPhone Topic")
        let iphoneNotebook = Notebook(id: nbId, name: "Transformers", docIds: [docId1, docId2], root: MindNode(id: rootId, title: "Root", children: [iphoneChild]))

        let iphoneLib = Library(docs: [iphoneDoc1, iphoneDoc2], notebooks: [iphoneNotebook], cards: [iphoneCard], links: [])

        // Merge with tombstone for deletedDocId
        let (merged, localChanged, remoteChanged) = CloudSync.mergeLibraries(local: macLib, remote: iphoneLib, deleted: [deletedDocId])
        XCTAssertTrue(localChanged)
        XCTAssertTrue(remoteChanged)

        // 1. Deleted doc is filtered out, both doc1 and doc2 are present
        XCTAssertEqual(merged.docs.count, 2)
        XCTAssertNil(merged.docs.first(where: { $0.id == deletedDocId }))

        // 2. doc1 took the newer iPhone readPage (9), DOING status, and merged custom tags ("AI" + "DeepLearning")
        let mDoc1 = merged.docs.first(where: { $0.id == docId1 })!
        XCTAssertEqual(mDoc1.readPage, 9)
        XCTAssertEqual(mDoc1.statusTag, DocStatusTag.doing)
        XCTAssertTrue(mDoc1.customTags.contains("AI"))
        XCTAssertTrue(mDoc1.customTags.contains("DeepLearning"))

        // 3. Card kept translation from iPhone and combined comments from Mac + iPhone
        XCTAssertEqual(merged.cards.count, 1)
        let mCard = merged.cards[0]
        XCTAssertEqual(mCard.translation, "主流序列转导模型基于复杂的循环或卷积神经网络。")
        XCTAssertTrue(mCard.comments.contains("Mac note"))
        XCTAssertTrue(mCard.comments.contains("iPhone note"))

        // 4. Mind map root merged children from both Mac and iPhone
        let mNb = merged.notebooks.first(where: { $0.id == nbId })!
        XCTAssertEqual(mNb.root.children.count, 2)
        XCTAssertEqual(Set(mNb.docIds), Set([docId1, docId2]))
    }

    func testCrossDeviceProgressConflictAndHistoryMerge() {
        let docId = UUID()
        let now = Date()

        let localDoc = Doc(
            id: docId,
            title: "Distributed Systems Paper",
            pageCount: 30,
            readPage: 18,
            readUpdatedAt: now.addingTimeInterval(-60),
            lastReadDevice: "MacBook Pro",
            lastReadDeviceId: "dev-mac",
            deviceProgressHistory: [
                DeviceProgressSnapshot(deviceId: "dev-mac", deviceName: "MacBook Pro", readPage: 18, narrationPage: 4, narrationSeg: 2, updatedAt: now.addingTimeInterval(-60))
            ],
            dailyReadingLog: ["2026-10-25": 10, "2026-10-26": 18],
            updatedAt: now.addingTimeInterval(-60)
        )

        let remoteDoc = Doc(
            id: docId,
            title: "Distributed Systems Paper",
            pageCount: 30,
            readPage: 6,
            readUpdatedAt: now,
            lastReadDevice: "iPhone 14",
            lastReadDeviceId: "dev-iphone",
            deviceProgressHistory: [
                DeviceProgressSnapshot(deviceId: "dev-iphone", deviceName: "iPhone 14", readPage: 6, narrationPage: 6, narrationSeg: 1, updatedAt: now)
            ],
            dailyReadingLog: ["2026-10-24": 3, "2026-10-26": 6],
            updatedAt: now
        )

        let (merged, localChanged, _) = CloudSync.mergeLibraries(
            local: Library(docs: [localDoc]),
            remote: Library(docs: [remoteDoc]),
            deleted: []
        )
        XCTAssertTrue(localChanged)
        let mDoc = merged.docs[0]
        // Conflict detected because remote device is on a much earlier page (6 vs 18) despite newer timestamp:
        // local higher page (18) is preserved until user chooses in conflict banner!
        XCTAssertEqual(mDoc.readPage, 18)
        XCTAssertNotNil(mDoc.pendingConflict)
        XCTAssertEqual(mDoc.pendingConflict?.localPage, 18)
        XCTAssertEqual(mDoc.pendingConflict?.remotePage, 6)
        XCTAssertEqual(mDoc.deviceProgressHistory.count, 2)
        XCTAssertEqual(mDoc.dailyReadingLog["2026-10-26"], 18)
        XCTAssertEqual(mDoc.dailyReadingLog["2026-10-24"], 3)
    }

    func testPerDocAudioVideoSpaceResetAndCloudAudioMigration() throws {
        let fm = FileManager.default
        let docId = UUID()
        let narrDir = Paths.docDir(docId).appendingPathComponent("narration", isDirectory: true)
        defer { try? fm.removeItem(at: Paths.docDir(docId)) }
        try fm.createDirectory(at: narrDir, withIntermediateDirectories: true)

        // Create local audio clip + narration script + video file
        let audioClip = narrDir.appendingPathComponent("p0-s0.m4a")
        let scriptFile = narrDir.appendingPathComponent("p0.json")
        let docVideo = Paths.docDir(docId).appendingPathComponent("export.mp4")
        try Data(repeating: 0xAA, count: 4096).write(to: audioClip)
        try Data("{\"segments\":[]}".utf8).write(to: scriptFile)
        try Data(repeating: 0xBB, count: 8192).write(to: docVideo)

        let usageBefore = StorageManager.docMediaUsage(docId, title: "TestPaper")
        XCTAssertEqual(usageBefore.audioCount, 1)
        XCTAssertEqual(usageBefore.videoCount, 1)
        XCTAssertEqual(usageBefore.scriptCount, 1)
        XCTAssertGreaterThanOrEqual(usageBefore.audioBytes, 4096)
        XCTAssertGreaterThanOrEqual(usageBefore.videoBytes, 8192)

        // Reset audio & video only (keep scripts)
        let freed = StorageManager.resetDocMedia(docId, title: "TestPaper", includeScripts: false, includeBilingual: false)
        XCTAssertGreaterThanOrEqual(freed, 4096 + 8192)
        XCTAssertFalse(fm.fileExists(atPath: audioClip.path))
        XCTAssertFalse(fm.fileExists(atPath: docVideo.path))
        XCTAssertTrue(fm.fileExists(atPath: scriptFile.path))

        // Test upgrade migration: audio in cloudDir is migrated to localDir before being purged from cloudDir
        let tmpCloudNarr = fm.temporaryDirectory.appendingPathComponent("cloud-narr-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpCloudNarr) }
        try fm.createDirectory(at: tmpCloudNarr, withIntermediateDirectories: true)
        let cloudClip = tmpCloudNarr.appendingPathComponent("p1-s0.m4a")
        try Data(repeating: 0xCC, count: 2048).write(to: cloudClip)

        CloudSync.purgeAudioClipsFromCloud(cloudDir: tmpCloudNarr, migrateToLocalDir: narrDir)
        XCTAssertFalse(fm.fileExists(atPath: cloudClip.path), "Cloud audio clip should be removed from iCloud")
        XCTAssertTrue(fm.fileExists(atPath: narrDir.appendingPathComponent("p1-s0.m4a").path), "Cloud audio clip should be migrated to local storage on upgrade")
    }
}


