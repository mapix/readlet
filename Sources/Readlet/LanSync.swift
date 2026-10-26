@preconcurrency import Dispatch
import Foundation
import Network
import PDFKit

/// Automatic zero-configuration peer-to-peer local network (Bonjour `_readlet-sync._tcp`) sync engine.
/// Syncs `library.json`, `original.pdf`, `thumb.png`, `narration/*.json`, annotations, and card images
/// directly between Mac and iPhone/iPad over Wi-Fi / LAN / USB — even when iCloud Drive (`Mobile Documents`)
/// is disabled or unprovisioned. Strictly excludes audio (`*.m4a`, `*.wav`), video, and `bi2-*` caches.
final class LanSync: @unchecked Sendable {
    static let shared = LanSync()
    static let serviceType = "_readlet-sync._tcp"

    struct DocManifest: Codable {
        var hasPDF: Bool
        var pdfSize: Int
        var hasThumb: Bool
        var jsonFiles: [String]
        var narrationJsonFiles: [String]
    }

    struct PeerManifest: Codable {
        var deviceId: String
        var deviceName: String
        var docs: [String: DocManifest]
        var images: [String]
    }

    private let queue = DispatchQueue(label: "io.novarock.readlet.lansync", qos: .utility)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: NWEndpoint] = [:]
    private let lock = NSLock()
    private var started = false

    private init() {}

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        startListener()
        startBrowser()
    }

    var activePeerEndpoints: [NWEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return Array(peers.values)
    }

    var hasActivePeers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !peers.isEmpty
    }

    // MARK: - Bonjour Listener (Server)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: DeviceIdentity.currentDeviceId, type: Self.serviceType)
            l.newConnectionHandler = { [weak self] conn in
                self?.handleIncomingConnection(conn)
            }
            l.stateUpdateHandler = { _ in }
            l.start(queue: queue)
            self.listener = l
        } catch {
            // Listener unavailable in restricted test environments
        }
    }

    // MARK: - Bonjour Browser (Client Discovery)

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let myId = DeviceIdentity.currentDeviceId
            var updated: [String: NWEndpoint] = [:]
            for res in results {
                if case let .service(name, _, _, _) = res.endpoint {
                    if name == myId { continue }
                    updated[name] = res.endpoint
                }
            }
            self.lock.lock()
            let hadPeers = !self.peers.isEmpty
            self.peers = updated
            let nowHasPeers = !updated.isEmpty
            self.lock.unlock()

            if !hadPeers && nowHasPeers {
                Task { @MainActor in
                    CloudSync.shared.scheduleSync(delay: 0.5, silent: true)
                }
            }
        }
        b.stateUpdateHandler = { _ in }
        b.start(queue: queue)
        self.browser = b
    }

    // MARK: - HTTP/1.0 Server over NWConnection

    private func handleIncomingConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveFullHTTPRequest(conn: conn, accumulated: Data())
    }

    private func receiveFullHTTPRequest(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            let sep = Data([13, 10, 13, 10]) // \r\n\r\n
            if let range = buffer.range(of: sep) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let bodyStart = range.upperBound
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.parseContentLength(headerStr)
                if buffer.count - bodyStart >= contentLength || isComplete {
                    let body = buffer.subdata(in: bodyStart..<min(buffer.count, bodyStart + contentLength))
                    self.processHTTPRequest(header: headerStr, body: body, conn: conn)
                    return
                }
            }
            if isComplete || error != nil || buffer.count > 120_000_000 {
                conn.cancel()
                return
            }
            self.receiveFullHTTPRequest(conn: conn, accumulated: buffer)
        }
    }

    private static func parseContentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func processHTTPRequest(header: String, body: Data, conn: NWConnection) {
        let firstLine = header.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(conn: conn, status: "400 Bad Request", body: Data())
            return
        }
        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let path = rawPath.removingPercentEncoding ?? rawPath

        let base = Paths.base
        let fm = FileManager.default

        if method == "GET" && path == "/manifest.json" {
            let manifest = buildLocalManifest(base: base)
            let data = (try? JSONEncoder().encode(manifest)) ?? Data()
            sendResponse(conn: conn, status: "200 OK", contentType: "application/json", body: data)
            return
        }

        if method == "GET" && ["/library.json", "/deleted-items.json", "/cloud-settings.json", "/flashcards.json", "/copilot.json"].contains(path) {
            let fileURL = base.appendingPathComponent(String(path.dropFirst()))
            if let data = try? Data(contentsOf: fileURL) {
                sendResponse(conn: conn, status: "200 OK", contentType: "application/json", body: data)
            } else {
                sendResponse(conn: conn, status: "404 Not Found", body: Data())
            }
            return
        }

        if method == "POST" && path == "/library.json" {
            guard let remoteLib = try? JSONDecoder().decode(Library.self, from: body) else {
                sendResponse(conn: conn, status: "400 Bad Request", body: Data())
                return
            }
            let localTomb = CloudSync.loadTombstones(from: base.appendingPathComponent("deleted-items.json"))
            let deletedSet = Set(localTomb.deletedIds.keys)
            let diskLibURL = base.appendingPathComponent("library.json")
            let localLib = (try? Data(contentsOf: diskLibURL)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
            let (merged, localChanged, _) = CloudSync.mergeLibraries(local: localLib, remote: remoteLib, deleted: deletedSet)
            let encoded = (try? JSONEncoder().encode(merged)) ?? Data()
            if localChanged, !encoded.isEmpty {
                try? encoded.write(to: diskLibURL, options: .atomic)
                Task { @MainActor in
                    CloudSync.shared.scheduleSync(delay: 0.2, silent: true)
                }
            }
            sendResponse(conn: conn, status: "200 OK", contentType: "application/json", body: encoded)
            return
        }

        // Serve or accept `/images/<UUID>.png`
        if path.hasPrefix("/images/") {
            let fileName = String(path.dropFirst("/images/".count))
            guard !fileName.contains(".."), !fileName.contains("/"), fileName.lowercased().hasSuffix(".png") else {
                sendResponse(conn: conn, status: "403 Forbidden", body: Data())
                return
            }
            let fileURL = base.appendingPathComponent("images/\(fileName)")
            if method == "GET" {
                if let d = try? Data(contentsOf: fileURL) {
                    sendResponse(conn: conn, status: "200 OK", contentType: "image/png", body: d)
                } else {
                    sendResponse(conn: conn, status: "404 Not Found", body: Data())
                }
                return
            } else if method == "PUT", !body.isEmpty {
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? body.write(to: fileURL, options: .atomic)
                sendResponse(conn: conn, status: "200 OK", body: Data("OK".utf8))
                return
            }
        }

        // Serve or accept `/docs/<UUID>/...` (strictly PDF, thumb.png, and JSON files — NEVER audio/video!)
        if path.hasPrefix("/docs/") {
            let rel = String(path.dropFirst("/docs/".count))
            let comps = rel.split(separator: "/").map(String.init)
            guard comps.count >= 2, UUID(uuidString: comps[0]) != nil, !comps.contains("..") else {
                sendResponse(conn: conn, status: "403 Forbidden", body: Data())
                return
            }
            let docIdStr = comps[0]
            let subPath = comps.dropFirst().joined(separator: "/")
            let allowedSingle = ["original.pdf", "thumb.png", "flashcards.json", "trans.json", "chat.json"]
            let isAllowedNarrationJSON = comps.count == 3 && comps[1] == "narration" && comps[2].lowercased().hasSuffix(".json")
            guard allowedSingle.contains(subPath) || isAllowedNarrationJSON else {
                sendResponse(conn: conn, status: "403 Forbidden", body: Data())
                return
            }
            let targetURL = base.appendingPathComponent("docs/\(docIdStr)/\(subPath)")
            if method == "GET" {
                if let d = try? Data(contentsOf: targetURL), !d.isEmpty {
                    let ctype = subPath.hasSuffix(".pdf") ? "application/pdf" : (subPath.hasSuffix(".png") ? "image/png" : "application/json")
                    sendResponse(conn: conn, status: "200 OK", contentType: ctype, body: d)
                } else {
                    sendResponse(conn: conn, status: "404 Not Found", body: Data())
                }
                return
            } else if method == "PUT", !body.isEmpty {
                try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if subPath == "original.pdf" {
                    let tmp = targetURL.deletingLastPathComponent().appendingPathComponent(".lan-tmp-\(UUID().uuidString).pdf")
                    try? body.write(to: tmp, options: .atomic)
                    if PDFDocument(url: tmp) != nil {
                        if fm.fileExists(atPath: targetURL.path) {
                            try? fm.removeItem(at: targetURL)
                        }
                        try? fm.moveItem(at: tmp, to: targetURL)
                    } else {
                        try? fm.removeItem(at: tmp)
                    }
                } else {
                    try? body.write(to: targetURL, options: .atomic)
                }
                sendResponse(conn: conn, status: "200 OK", body: Data("OK".utf8))
                return
            }
        }

        sendResponse(conn: conn, status: "404 Not Found", body: Data())
    }

    private func sendResponse(conn: NWConnection, status: String, contentType: String = "text/plain", body: Data) {
        let header = "HTTP/1.0 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func buildLocalManifest(base: URL) -> PeerManifest {
        let fm = FileManager.default
        var docsMap: [String: DocManifest] = [:]
        let docsRoot = base.appendingPathComponent("docs", isDirectory: true)
        if let docDirs = try? fm.contentsOfDirectory(at: docsRoot, includingPropertiesForKeys: nil) {
            for d in docDirs where UUID(uuidString: d.lastPathComponent) != nil {
                let docIdStr = d.lastPathComponent
                let pdfURL = d.appendingPathComponent("original.pdf")
                let pdfSize = (try? fm.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
                let hasPDF = pdfSize > 100
                let hasThumb = fm.fileExists(atPath: d.appendingPathComponent("thumb.png").path)
                var jsonFiles: [String] = []
                for jf in ["flashcards.json", "trans.json", "chat.json"] {
                    if fm.fileExists(atPath: d.appendingPathComponent(jf).path) {
                        jsonFiles.append(jf)
                    }
                }
                var narrFiles: [String] = []
                let narrDir = d.appendingPathComponent("narration", isDirectory: true)
                if let nlist = try? fm.contentsOfDirectory(atPath: narrDir.path) {
                    for nf in nlist where nf.lowercased().hasSuffix(".json") && !nf.hasPrefix(".") {
                        narrFiles.append(nf)
                    }
                }
                docsMap[docIdStr] = DocManifest(
                    hasPDF: hasPDF,
                    pdfSize: pdfSize,
                    hasThumb: hasThumb,
                    jsonFiles: jsonFiles,
                    narrationJsonFiles: narrFiles
                )
            }
        }
        var imgs: [String] = []
        let imgRoot = base.appendingPathComponent("images", isDirectory: true)
        if let ilist = try? fm.contentsOfDirectory(atPath: imgRoot.path) {
            for f in ilist where f.lowercased().hasSuffix(".png") && !f.hasPrefix(".") {
                imgs.append(f)
            }
        }
        return PeerManifest(
            deviceId: DeviceIdentity.currentDeviceId,
            deviceName: DeviceIdentity.currentDeviceName,
            docs: docsMap,
            images: imgs
        )
    }

    // MARK: - HTTP/1.0 Client over NWConnection

    func request(endpoint: NWEndpoint, method: String = "GET", path: String, body: Data = Data(), timeout: TimeInterval = 30.0) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let conn = NWConnection(to: endpoint, using: params)
            let stateBox = RequestStateBox(continuation: cont, connection: conn)

            let timeoutWork = DispatchWorkItem {
                stateBox.finish(with: nil)
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let header = "\(method) \(path) HTTP/1.0\r\nHost: readlet.local\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var reqData = Data(header.utf8)
                    reqData.append(body)
                    conn.send(content: reqData, completion: .contentProcessed { sendErr in
                        if sendErr != nil {
                            timeoutWork.cancel()
                            stateBox.finish(with: nil)
                            return
                        }
                        Self.readClientResponse(conn: conn, box: stateBox, timeoutWork: timeoutWork)
                    })
                case .failed, .cancelled:
                    timeoutWork.cancel()
                    stateBox.finish(with: nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private static func readClientResponse(conn: NWConnection, box: RequestStateBox, timeoutWork: DispatchWorkItem) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 524_288) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                box.append(data)
            }
            if isComplete || error != nil {
                timeoutWork.cancel()
                let raw = box.buffer
                let sep = Data([13, 10, 13, 10])
                guard let range = raw.range(of: sep) else {
                    box.finish(with: nil)
                    return
                }
                let headerStr = String(data: raw.subdata(in: 0..<range.lowerBound), encoding: .utf8) ?? ""
                let firstLine = headerStr.split(separator: "\r\n").first ?? ""
                guard firstLine.contains("200") else {
                    box.finish(with: nil)
                    return
                }
                let bodyData = raw.subdata(in: range.upperBound..<raw.count)
                box.finish(with: bodyData)
                return
            }
            readClientResponse(conn: conn, box: box, timeoutWork: timeoutWork)
        }
    }

    private final class RequestStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private let connection: NWConnection
        var buffer = Data()

        init(continuation: CheckedContinuation<Data?, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        func finish(with result: Data?) {
            lock.lock()
            guard let cont = continuation else {
                lock.unlock()
                return
            }
            continuation = nil
            lock.unlock()
            connection.cancel()
            cont.resume(returning: result)
        }
    }

    // MARK: - High-Level Peer Sync Operations

    /// Downloads a specific document's PDF, thumbnail, and narration JSONs from any available LAN peer.
    func downloadDocFromPeers(_ docId: UUID) async -> Bool {
        let endpoints = activePeerEndpoints
        guard !endpoints.isEmpty else { return false }
        let docIdStr = docId.uuidString
        let localDocDir = Paths.docDir(docId)
        let localPDF = Paths.pdf(docId)
        let fm = FileManager.default
        try? fm.createDirectory(at: localDocDir, withIntermediateDirectories: true)

        for ep in endpoints {
            if !Paths.hasLocalPDF(docId) {
                if let pdfData = await request(endpoint: ep, path: "/docs/\(docIdStr)/original.pdf", timeout: 45.0),
                   pdfData.count > 100 {
                    let tmp = localDocDir.appendingPathComponent(".lan-dl-\(UUID().uuidString).pdf")
                    try? pdfData.write(to: tmp, options: .atomic)
                    if PDFDocument(url: tmp) != nil {
                        if fm.fileExists(atPath: localPDF.path) {
                            try? fm.removeItem(at: localPDF)
                        }
                        try? fm.moveItem(at: tmp, to: localPDF)
                    } else {
                        try? fm.removeItem(at: tmp)
                    }
                }
            }
            let thumbURL = localDocDir.appendingPathComponent("thumb.png")
            if !fm.fileExists(atPath: thumbURL.path),
               let thumbData = await request(endpoint: ep, path: "/docs/\(docIdStr)/thumb.png", timeout: 10.0),
               !thumbData.isEmpty {
                try? thumbData.write(to: thumbURL, options: .atomic)
            }
            if let manifestData = await request(endpoint: ep, path: "/manifest.json", timeout: 10.0),
               let manifest = try? JSONDecoder().decode(PeerManifest.self, from: manifestData),
               let dm = manifest.docs[docIdStr] {
                for jf in dm.jsonFiles {
                    let dst = localDocDir.appendingPathComponent(jf)
                    if !fm.fileExists(atPath: dst.path),
                       let jd = await request(endpoint: ep, path: "/docs/\(docIdStr)/\(jf)", timeout: 10.0) {
                        try? jd.write(to: dst, options: .atomic)
                    }
                }
                let narrDir = localDocDir.appendingPathComponent("narration", isDirectory: true)
                try? fm.createDirectory(at: narrDir, withIntermediateDirectories: true)
                for nf in dm.narrationJsonFiles {
                    let dst = narrDir.appendingPathComponent(nf)
                    if !fm.fileExists(atPath: dst.path),
                       let nd = await request(endpoint: ep, path: "/docs/\(docIdStr)/narration/\(nf)", timeout: 10.0) {
                        try? nd.write(to: dst, options: .atomic)
                    }
                }
            }
            if Paths.hasLocalPDF(docId) {
                return true
            }
        }
        return Paths.hasLocalPDF(docId)
    }

    /// Performs a full bidirectional sync of `library.json`, missing PDFs, thumbnails, narration JSONs, and card images with all discovered LAN peers.
    func syncWithPeers(localBase: URL, workingLib: inout Library, deletedSet: Set<UUID>) async -> Bool {
        let endpoints = activePeerEndpoints
        guard !endpoints.isEmpty else { return false }
        let fm = FileManager.default
        var anyLocalChange = false

        for ep in endpoints {
            // 1. Exchange & merge library.json
            if let currentEncoded = try? JSONEncoder().encode(workingLib),
               let respData = await request(endpoint: ep, method: "POST", path: "/library.json", body: currentEncoded, timeout: 15.0),
               let peerLib = try? JSONDecoder().decode(Library.self, from: respData) {
                let (merged, localChanged, _) = CloudSync.mergeLibraries(local: workingLib, remote: peerLib, deleted: deletedSet)
                if localChanged {
                    workingLib = merged
                    anyLocalChange = true
                }
            }

            // 2. Fetch peer manifest to sync missing PDFs, thumbnails, narration scripts, and images
            guard let manifestData = await request(endpoint: ep, path: "/manifest.json", timeout: 10.0),
                  let manifest = try? JSONDecoder().decode(PeerManifest.self, from: manifestData) else {
                continue
            }

            for doc in workingLib.docs {
                let docIdStr = doc.id.uuidString
                let localDocDir = localBase.appendingPathComponent("docs/\(docIdStr)", isDirectory: true)
                try? fm.createDirectory(at: localDocDir, withIntermediateDirectories: true)
                let localPDF = localDocDir.appendingPathComponent("original.pdf")
                let localHasPDF = (try? fm.attributesOfItem(atPath: localPDF.path)[.size] as? Int ?? 0) ?? 0 > 100
                let peerDoc = manifest.docs[docIdStr]

                // Pull missing PDF from peer
                if !localHasPDF, peerDoc?.hasPDF == true {
                    if let pdfData = await request(endpoint: ep, path: "/docs/\(docIdStr)/original.pdf", timeout: 45.0),
                       pdfData.count > 100 {
                        let tmp = localDocDir.appendingPathComponent(".lan-dl-\(UUID().uuidString).pdf")
                        try? pdfData.write(to: tmp, options: .atomic)
                        if PDFDocument(url: tmp) != nil {
                            if fm.fileExists(atPath: localPDF.path) { try? fm.removeItem(at: localPDF) }
                            try? fm.moveItem(at: tmp, to: localPDF)
                            anyLocalChange = true
                        } else {
                            try? fm.removeItem(at: tmp)
                        }
                    }
                } else if localHasPDF, peerDoc?.hasPDF != true {
                    // Push our local PDF to peer if peer is missing it
                    if let pdfData = try? Data(contentsOf: localPDF), pdfData.count > 100 {
                        _ = await request(endpoint: ep, method: "PUT", path: "/docs/\(docIdStr)/original.pdf", body: pdfData, timeout: 45.0)
                    }
                }

                // Thumbnail
                let localThumb = localDocDir.appendingPathComponent("thumb.png")
                if !fm.fileExists(atPath: localThumb.path), peerDoc?.hasThumb == true {
                    if let td = await request(endpoint: ep, path: "/docs/\(docIdStr)/thumb.png", timeout: 10.0), !td.isEmpty {
                        try? td.write(to: localThumb, options: .atomic)
                    }
                } else if fm.fileExists(atPath: localThumb.path), peerDoc?.hasThumb != true {
                    if let td = try? Data(contentsOf: localThumb) {
                        _ = await request(endpoint: ep, method: "PUT", path: "/docs/\(docIdStr)/thumb.png", body: td, timeout: 10.0)
                    }
                }

                // Doc JSON files & Narration JSON scripts
                if let pDoc = peerDoc {
                    for jf in pDoc.jsonFiles {
                        let dst = localDocDir.appendingPathComponent(jf)
                        if !fm.fileExists(atPath: dst.path),
                           let jd = await request(endpoint: ep, path: "/docs/\(docIdStr)/\(jf)", timeout: 10.0) {
                            try? jd.write(to: dst, options: .atomic)
                        }
                    }
                    let narrDir = localDocDir.appendingPathComponent("narration", isDirectory: true)
                    try? fm.createDirectory(at: narrDir, withIntermediateDirectories: true)
                    for nf in pDoc.narrationJsonFiles {
                        let dst = narrDir.appendingPathComponent(nf)
                        if !fm.fileExists(atPath: dst.path),
                           let nd = await request(endpoint: ep, path: "/docs/\(docIdStr)/narration/\(nf)", timeout: 10.0) {
                            try? nd.write(to: dst, options: .atomic)
                        }
                    }
                }
            }

            // Card images
            let localImgDir = localBase.appendingPathComponent("images", isDirectory: true)
            try? fm.createDirectory(at: localImgDir, withIntermediateDirectories: true)
            for imgName in manifest.images {
                let dst = localImgDir.appendingPathComponent(imgName)
                if !fm.fileExists(atPath: dst.path),
                   let idata = await request(endpoint: ep, path: "/images/\(imgName)", timeout: 10.0), !idata.isEmpty {
                    try? idata.write(to: dst, options: .atomic)
                }
            }
        }
        return anyLocalChange
    }
}
