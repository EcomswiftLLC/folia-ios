import SwiftUI
import UIKit
import ImageIO
import PDFKit

// MARK: - Records

struct PageRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var filter: ScanFilter = .auto
    /// Page corners inside the captured photo. nil means the whole capture is the page.
    var quad: Quad? = nil
    var quarterTurns: Int = 0
    /// Recognised text, in the geometry of the finished page. Cleared whenever crop or rotation changes.
    var ocr: [OCRLine]? = nil
    /// Bumped on every visible change, so thumbnails know to redraw.
    var version: Int = 0
}

struct DocRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// True while the title is still the date-based default, so it may be replaced by the first line of text.
    var autoTitle: Bool = true
    var createdAt = Date()
    var modifiedAt = Date()
    var pages: [PageRecord] = []

    /// All recognised text of the document, page by page.
    var searchText: String {
        pages.compactMap { $0.ocr }.map { OCREngine.plainText($0) }.joined(separator: "\n")
    }
}

// Tolerant reading: a record written by an older or newer version, or with one damaged field, still opens.
// Kept in extensions so the memberwise initialisers stay available.

extension PageRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        let rawFilter: String? = (try? c.decodeIfPresent(String.self, forKey: .filter)) ?? nil
        filter = rawFilter.flatMap { ScanFilter(rawValue: $0) } ?? .auto
        quad = (try? c.decodeIfPresent(Quad.self, forKey: .quad)) ?? nil
        quarterTurns = (try? c.decodeIfPresent(Int.self, forKey: .quarterTurns)) ?? 0
        ocr = (try? c.decodeIfPresent([OCRLine].self, forKey: .ocr)) ?? nil
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
    }
}

extension DocRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled scan"
        autoTitle = (try? c.decodeIfPresent(Bool.self, forKey: .autoTitle)) ?? false
        let created: Date = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        createdAt = created
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? created
        let lossy: [LossyDecodable<PageRecord>]? = (try? c.decodeIfPresent([LossyDecodable<PageRecord>].self, forKey: .pages)) ?? nil
        pages = (lossy ?? []).compactMap { $0.value }
    }
}

/// Decodes one element of an array, or nil when that element is damaged, so one bad entry does not lose the rest.
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Files on disk

struct PageStorage {
    let root: URL

    static let standard = PageStorage(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folia", isDirectory: true)
    )

    var pagesDirectory: URL { root.appendingPathComponent("Pages", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("library.json") }
    var signatureURL: URL { root.appendingPathComponent("signature.png") }

    func prepare() {
        try? FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
    }

    func sourceURL(_ id: UUID) -> URL { pagesDirectory.appendingPathComponent("\(id.uuidString).jpg") }

    func loadSource(_ id: UUID, maxPixel: Int = 3000) -> CGImage? {
        guard let data = try? Data(contentsOf: sourceURL(id)) else { return nil }
        return PhotoLoader.decode(data, maxPixel: maxPixel)
    }

    /// The finished page: straightened, filtered and rotated. `maxSide` caps the longest side in pixels.
    func render(_ page: PageRecord, maxSide: Int, decodeSide: Int = 3000) -> CGImage? {
        guard let source = loadSource(page.id, maxPixel: decodeSide) else { return nil }
        return PageRenderer.render(source, filter: page.filter, quad: page.quad, quarterTurns: page.quarterTurns, maxSide: maxSide)
    }
}

/// What happened when captures were stored: the document they went into, how many pages were stored, and how many
/// could not be (for example the device is out of space).
struct InsertResult: Equatable {
    var docID: UUID?
    var stored = 0
    var failed = 0
}

/// Checks a library file for entries the tolerant decoder would silently repair or drop.
enum LibraryAudit {
    /// Number of page entries that are not objects, or whose id is missing or is not a valid UUID. Such a page is read
    /// with a fresh id (or dropped), so its picture file on disk no longer belongs to any page.
    static func unreadablePages(in data: Data) -> Int {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return 0 }
        var bad = 0
        for entry in entries {
            guard let doc = entry as? [String: Any], let pages = doc["pages"] as? [Any] else { continue }
            for page in pages {
                if let dict = page as? [String: Any], let raw = dict["id"] as? String, UUID(uuidString: raw) != nil { continue }
                bad += 1
            }
        }
        return bad
    }
}

// MARK: - Importing pictures

enum ScanImporter {
    /// A capture ready to be stored: JPEG bytes plus the page edges found in it.
    struct Source {
        var data: Data
        var quad: Quad?
    }

    /// `detect` looks for the page edges in a photo. Pictures from the document camera are already cropped, so they skip it.
    static func makeSource(_ image: CGImage, detect: Bool) -> Source? {
        guard let capped = ImageCodec.scaled(image, maxPixel: 2600),
              let data = ImageCodec.encode(capped, format: .jpeg, quality: 0.88) else { return nil }
        var quad: Quad?
        if detect {
            let small = ImageCodec.scaled(capped, maxPixel: 900) ?? capped
            if let found = DocumentDetector.detect(small), !found.isFull { quad = found }
        }
        return Source(data: data, quad: quad)
    }

    /// Prepares pictures one at a time, so only one full-size picture is being worked on at once. Call off the main thread.
    static func makeSources(_ images: [CGImage], detect: Bool) -> [Source] {
        var sources: [Source] = []
        for image in images {
            autoreleasepool {
                if let source = makeSource(image, detect: detect) { sources.append(source) }
            }
        }
        return sources
    }

    /// Decodes a picture file and prepares it. Call off the main thread.
    static func makeSource(data: Data, detect: Bool) -> Source? {
        var source: Source?
        autoreleasepool {
            if let image = PhotoLoader.decode(data, maxPixel: 3000) {
                source = makeSource(image, detect: detect)
            }
        }
        return source
    }

    /// Draws and prepares the pages of a PDF one at a time (all pages, or only `pages`). Call off the main thread,
    /// on a document no other thread is using.
    static func makeSources(pdf document: PDFDocument, pages: [Int]? = nil, maxSide: CGFloat = 2400) -> [Source] {
        var sources: [Source] = []
        for index in pages ?? Array(0..<document.pageCount) {
            autoreleasepool {
                if let image = PDFOps.images(document, pages: [index], maxSide: maxSide).first,
                   let source = makeSource(image, detect: false) {
                    sources.append(source)
                }
            }
        }
        return sources
    }

    static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = image.size
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}

// MARK: - Store

@MainActor
final class DocStore: ObservableObject {
    @Published private(set) var docs: [DocRecord] = []

    let storage: PageStorage
    /// Text recognition waiting to run after a crop or rotation, per document.
    private var pendingRecognition: [UUID: Task<Void, Never>] = [:]

    init(storage: PageStorage = .standard) {
        self.storage = storage
        storage.prepare()
        load()
    }

    // MARK: Reading

    func doc(_ id: UUID) -> DocRecord? { docs.first { $0.id == id } }

    func page(_ docID: UUID, _ pageID: UUID) -> PageRecord? {
        doc(docID)?.pages.first { $0.id == pageID }
    }

    var totalPages: Int { docs.reduce(0) { $0 + $1.pages.count } }

    static func matches(_ doc: DocRecord, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if doc.title.range(of: trimmed, options: options) != nil { return true }
        return doc.searchText.range(of: trimmed, options: options) != nil
    }

    static func defaultTitle(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return "Scan \(formatter.string(from: date))"
    }

    // MARK: Adding

    /// Stores captures as new pages, either in a new document or appended to `docID`. Returns the document id.
    /// Use `insertReporting` to learn how many pages could not be written.
    @discardableResult
    func insert(_ sources: [ScanImporter.Source], title: String? = nil, into docID: UUID? = nil, filter: ScanFilter = FoliaPrefs.defaultFilter) -> UUID? {
        insertReporting(sources, title: title, into: docID, filter: filter).docID
    }

    /// Same as `insert`, but also reports how many pages were stored and how many could not be written to disk.
    func insertReporting(_ sources: [ScanImporter.Source], title: String? = nil, into docID: UUID? = nil, filter: ScanFilter = FoliaPrefs.defaultFilter) -> InsertResult {
        var result = InsertResult()
        guard !sources.isEmpty else { return result }
        var pages: [PageRecord] = []
        for source in sources {
            var page = PageRecord()
            page.filter = filter
            page.quad = source.quad
            do {
                try source.data.write(to: storage.sourceURL(page.id), options: .atomic)
                pages.append(page)
            } catch {
                result.failed += 1
            }
        }
        guard !pages.isEmpty else { return result }
        result.stored = pages.count
        if let docID, let index = docs.firstIndex(where: { $0.id == docID }) {
            docs[index].pages.append(contentsOf: pages)
            docs[index].modifiedAt = Date()
            save()
            result.docID = docID
            return result
        }
        var record = DocRecord(title: title ?? Self.defaultTitle())
        record.autoTitle = title == nil
        record.pages = pages
        docs.insert(record, at: 0)
        save()
        result.docID = record.id
        return result
    }

    /// Stores captures that are already prepared (scaled and JPEG encoded) and starts reading their text.
    @discardableResult
    func importSources(_ sources: [ScanImporter.Source], into docID: UUID? = nil, title: String? = nil) -> UUID? {
        importSourcesReporting(sources, into: docID, title: title).docID
    }

    /// Same as `importSources`, but also reports how many pages could not be stored.
    func importSourcesReporting(_ sources: [ScanImporter.Source], into docID: UUID? = nil, title: String? = nil) -> InsertResult {
        let result = insertReporting(sources, title: title, into: docID)
        if let id = result.docID { Task { await self.recognizeText(docID: id) } }
        return result
    }

    /// Adds the pages of a PDF in small batches, so a long PDF never holds all its prepared pages in memory: each
    /// batch is drawn off the main thread and written to disk before the next one starts. Text recognition starts once,
    /// after the last batch. Pages that could not be drawn or stored are counted in `failed`.
    func importPDF(_ document: PDFDocument, title: String? = nil, into docID: UUID? = nil, maxSide: CGFloat = 2400, batchSize: Int = 10) async -> InsertResult {
        var total = InsertResult()
        var target = docID
        let count = document.pageCount
        let step = max(1, batchSize)
        var start = 0
        while start < count {
            let indices = Array(start..<min(count, start + step))
            start += step
            let sources: [ScanImporter.Source] = await Task.detached(priority: .userInitiated) {
                ScanImporter.makeSources(pdf: document, pages: indices, maxSide: maxSide)
            }.value
            total.failed += indices.count - sources.count
            guard !sources.isEmpty else { continue }
            let part = insertReporting(sources, title: title, into: target)
            total.failed += part.failed
            total.stored += part.stored
            if let id = part.docID { target = id }
        }
        total.docID = total.stored > 0 ? target : nil
        if let id = total.docID { Task { await self.recognizeText(docID: id) } }
        return total
    }

    // MARK: Editing

    func updateDoc(_ id: UUID, _ change: (inout DocRecord) -> Void) {
        guard let index = docs.firstIndex(where: { $0.id == id }) else { return }
        change(&docs[index])
        docs[index].modifiedAt = Date()
        save()
    }

    /// Applies a change to one page. Changing crop or rotation clears recognised text, because its positions no longer fit.
    func updatePage(_ docID: UUID, _ pageID: UUID, _ change: (inout PageRecord) -> Void) {
        guard let d = docs.firstIndex(where: { $0.id == docID }),
              let p = docs[d].pages.firstIndex(where: { $0.id == pageID }) else { return }
        let before = docs[d].pages[p]
        change(&docs[d].pages[p])
        var after = docs[d].pages[p]
        let geometryChanged = after.quad != before.quad || after.quarterTurns != before.quarterTurns
        if geometryChanged { after.ocr = nil }
        after.version = before.version + 1
        docs[d].pages[p] = after
        docs[d].modifiedAt = Date()
        save()
        if geometryChanged { scheduleRecognition(docID) }
    }

    /// Reads the text again shortly after crop or rotation changed, so search keeps finding the page. Rotating
    /// several times in a row starts only one pass.
    private func scheduleRecognition(_ docID: UUID) {
        pendingRecognition[docID]?.cancel()
        pendingRecognition[docID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingRecognition[docID] = nil
            await self.recognizeText(docID: docID)
        }
    }

    /// Reads text for documents whose pages have none yet (for example after an edit just before the app closed).
    /// One document at a time, at low priority.
    private func recognizeMissingText() async {
        let ids = docs.filter { doc in doc.pages.contains { $0.ocr == nil } }.map(\.id)
        for id in ids {
            if Task.isCancelled { return }
            await recognizeText(docID: id)
        }
    }

    func rotate(_ docID: UUID, _ pageID: UUID, by turns: Int) {
        updatePage(docID, pageID) { $0.quarterTurns = (($0.quarterTurns + turns) % 4 + 4) % 4 }
    }

    func setFilterForAll(_ docID: UUID, _ filter: ScanFilter) {
        guard let d = docs.firstIndex(where: { $0.id == docID }) else { return }
        for p in docs[d].pages.indices {
            docs[d].pages[p].filter = filter
            docs[d].pages[p].version += 1
        }
        docs[d].modifiedAt = Date()
        save()
    }

    func deletePage(_ docID: UUID, _ pageID: UUID) {
        guard let d = docs.firstIndex(where: { $0.id == docID }) else { return }
        docs[d].pages.removeAll { $0.id == pageID }
        try? FileManager.default.removeItem(at: storage.sourceURL(pageID))
        if docs[d].pages.isEmpty {
            docs.remove(at: d)
        } else {
            docs[d].modifiedAt = Date()
        }
        save()
    }

    func movePages(_ docID: UUID, from: IndexSet, to: Int) {
        guard let d = docs.firstIndex(where: { $0.id == docID }) else { return }
        docs[d].pages.move(fromOffsets: from, toOffset: to)
        docs[d].modifiedAt = Date()
        save()
    }

    func rename(_ docID: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        updateDoc(docID) { $0.title = clean; $0.autoTitle = false }
    }

    func deleteDoc(_ id: UUID) {
        guard let index = docs.firstIndex(where: { $0.id == id }) else { return }
        for page in docs[index].pages { try? FileManager.default.removeItem(at: storage.sourceURL(page.id)) }
        docs.remove(at: index)
        save()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let original = doc(id) else { return nil }
        var copy = DocRecord(title: original.title + " copy")
        copy.autoTitle = false
        for page in original.pages {
            var newPage = page
            newPage.id = UUID()
            newPage.version = 0
            do {
                try FileManager.default.copyItem(at: storage.sourceURL(page.id), to: storage.sourceURL(newPage.id))
                copy.pages.append(newPage)
            } catch { continue }
        }
        guard !copy.pages.isEmpty else { return nil }
        docs.insert(copy, at: 0)
        save()
        return copy.id
    }

    /// Joins several documents into a new one. The originals stay.
    @discardableResult
    func combine(_ ids: [UUID], title: String) -> UUID? {
        var merged = DocRecord(title: title)
        merged.autoTitle = false
        for id in ids {
            guard let source = doc(id) else { continue }
            for page in source.pages {
                var newPage = page
                newPage.id = UUID()
                newPage.version = 0
                do {
                    try FileManager.default.copyItem(at: storage.sourceURL(page.id), to: storage.sourceURL(newPage.id))
                    merged.pages.append(newPage)
                } catch { continue }
            }
        }
        guard !merged.pages.isEmpty else { return nil }
        docs.insert(merged, at: 0)
        save()
        return merged.id
    }

    // MARK: Text recognition

    /// Reads the text of every page that has none yet. Safe to call again: finished pages are skipped.
    func recognizeText(docID: UUID, force: Bool = false) async {
        guard let record = doc(docID) else { return }
        let storage = self.storage
        for page in record.pages where force || page.ocr == nil {
            // Another pass may have read this page while an earlier one was busy: do not read it twice.
            if !force, let latest = self.page(docID, page.id), latest.ocr != nil { continue }
            let snapshot = page
            let lines: [OCRLine] = await Task.detached(priority: .utility) {
                guard let image = storage.render(snapshot, maxSide: 2000) else { return [] }
                return OCREngine.recognize(image)
            }.value
            setOCR(docID, pageID: page.id, lines: lines, expected: snapshot)
        }
        applyAutoTitle(docID)
    }

    private func setOCR(_ docID: UUID, pageID: UUID, lines: [OCRLine], expected: PageRecord) {
        guard let d = docs.firstIndex(where: { $0.id == docID }),
              let p = docs[d].pages.firstIndex(where: { $0.id == pageID }) else { return }
        // Crop or rotation changed while the text was being read: the positions no longer fit, so drop this
        // result (the scheduled pass reads it again). A new look (filter) does not move text, so it is kept.
        let current = docs[d].pages[p]
        guard current.quad == expected.quad, current.quarterTurns == expected.quarterTurns else { return }
        docs[d].pages[p].ocr = lines
        save()
    }

    static func suggestedTitle(from lines: [OCRLine]) -> String? {
        for line in lines.prefix(6) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = text.filter { $0.isLetter }.count
            if letters >= 4 && text.count <= 60 {
                return String(text.prefix(40))
            }
        }
        return nil
    }

    private func applyAutoTitle(_ docID: UUID) {
        guard let record = doc(docID), record.autoTitle,
              let lines = record.pages.first?.ocr,
              let title = Self.suggestedTitle(from: lines) else { return }
        updateDoc(docID) { $0.title = title; $0.autoTitle = false }
    }

    // MARK: Saving

    /// True when library.json could not be read or decoded this session. Unreferenced page files are then kept,
    /// because they may belong to documents in the preserved copy.
    @Published private(set) var indexWasDamaged = false
    /// True while saving would overwrite a library file that could not be read and was not preserved.
    private var saveBlocked = false
    /// True when library.json exists but could not be opened at all this session.
    private var indexUnreadable = false
    /// False when the most recent save failed.
    @Published private(set) var lastSaveSucceeded = true

    static let corruptIndexName = "library.corrupt.json"
    private var saveFailedMarkerURL: URL { storage.root.appendingPathComponent("save-failed.marker") }

    /// A problem with the library file that the person must be told about, most serious first.
    enum LibraryProblem: Equatable {
        /// library.json exists but could not be opened. Nothing is saved over it this session.
        case unreadable
        /// The last attempt to write the library failed (for example the device is full).
        case saveFailed
        /// Part of library.json was damaged. A copy of the original was kept.
        case damaged
    }

    var libraryProblem: LibraryProblem? {
        if indexUnreadable { return .unreadable }
        if !lastSaveSucceeded { return .saveFailed }
        if indexWasDamaged { return .damaged }
        return nil
    }

    /// Tries to write the library again, for the "Try again" button after a failed save.
    func retrySave() { save() }

    /// True when a damaged library file was kept aside at some point (library.corrupt.json or a dated copy).
    private var hasPreservedCopy: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.root.path)) ?? []
        return names.contains { $0.hasPrefix("library.corrupt") }
    }

    private func load() {
        let fm = FileManager.default
        let url = storage.indexURL
        // Nothing saved yet: a fresh install. Page files are left alone either way.
        guard fm.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            // The file is there but cannot be read right now (for example still protected). Never overwrite it.
            indexWasDamaged = true
            indexUnreadable = true
            saveBlocked = true
            return
        }
        let decoded: [LossyDecodable<DocRecord>]
        do {
            decoded = try JSONDecoder().decode([LossyDecodable<DocRecord>].self, from: data)
        } catch {
            // Damaged beyond reading: move it aside so it can be recovered, and start an empty library.
            indexWasDamaged = true
            if !preserveDamagedIndex(move: true) { saveBlocked = true }
            return
        }
        docs = decoded.compactMap { $0.value }
        // A page entry without a readable id is read with a fresh id (or dropped), which would leave its picture
        // file without an owner. Treat that as damage too, so the file is not cleaned up as an orphan.
        if docs.count < decoded.count || LibraryAudit.unreadablePages(in: data) > 0 {
            // Some documents or pages could not be read. Keep a copy of the original before anything is saved over it.
            indexWasDamaged = true
            if !preserveDamagedIndex(move: false) { saveBlocked = true }
        }
        let previousSaveFailed = fm.fileExists(atPath: saveFailedMarkerURL.path)
        if !indexWasDamaged && !previousSaveFailed {
            removeOrphans()
        }
        if !docs.isEmpty {
            Task { [weak self] in
                // Let the library appear first, then catch up on text that was never read.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.recognizeMissingText()
            }
        }
    }

    /// Keeps the damaged library file as library.corrupt.json (or a dated name when that exists already).
    @discardableResult
    private func preserveDamagedIndex(move: Bool) -> Bool {
        let fm = FileManager.default
        var target = storage.root.appendingPathComponent(Self.corruptIndexName)
        if fm.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            target = storage.root.appendingPathComponent("library.corrupt-\(stamp).json")
        }
        do {
            if move {
                try fm.moveItem(at: storage.indexURL, to: target)
            } else {
                try fm.copyItem(at: storage.indexURL, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    private func removeOrphans() {
        // After damage was found once, picture files without a page may still belong to the preserved copy of the
        // library, so they are never cleaned up automatically.
        guard !indexWasDamaged, lastSaveSucceeded, !hasPreservedCopy else { return }
        let used = Set(docs.flatMap { $0.pages.map { "\($0.id.uuidString).jpg" } })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.pagesDirectory.path)) ?? []
        for name in files where name.hasSuffix(".jpg") && !used.contains(name) {
            try? FileManager.default.removeItem(at: storage.pagesDirectory.appendingPathComponent(name))
        }
    }

    @discardableResult
    private func save() -> Bool {
        if saveBlocked {
            // A library that could not be read is never written over in this session. A damaged one is written
            // over only once a copy of it was kept.
            let fileStillThere = FileManager.default.fileExists(atPath: storage.indexURL.path)
            if indexUnreadable || (fileStillThere && !preserveDamagedIndex(move: false)) {
                lastSaveSucceeded = false
                return false
            }
            saveBlocked = false
        }
        do {
            let data = try JSONEncoder().encode(docs)
            try data.write(to: storage.indexURL, options: .atomic)
            if !lastSaveSucceeded || FileManager.default.fileExists(atPath: saveFailedMarkerURL.path) {
                try? FileManager.default.removeItem(at: saveFailedMarkerURL)
            }
            lastSaveSucceeded = true
            return true
        } catch {
            lastSaveSucceeded = false
            try? Data().write(to: saveFailedMarkerURL, options: .atomic)
            return false
        }
    }
}

// MARK: - Preferences

enum FoliaPrefs {
    static let filterKey = "folia.defaultFilter"
    static let pageSizeKey = "folia.pageSize"
    static let qualityKey = "folia.quality"
    static let sortKey = "folia.sort"

    static var defaultFilter: ScanFilter {
        get { ScanFilter(rawValue: UserDefaults.standard.string(forKey: filterKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: filterKey) }
    }

    static var pageSize: PageSizeOption {
        get { PageSizeOption(rawValue: UserDefaults.standard.string(forKey: pageSizeKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pageSizeKey) }
    }

    static var quality: ExportQuality {
        get { ExportQuality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey) }
    }
}

// MARK: - Signature

enum SignatureStore {
    static func load(_ storage: PageStorage = .standard) -> UIImage? {
        guard let data = try? Data(contentsOf: storage.signatureURL) else { return nil }
        return UIImage(data: data)
    }

    static func save(_ image: UIImage, _ storage: PageStorage = .standard) {
        storage.prepare()
        if let data = image.pngData() { try? data.write(to: storage.signatureURL, options: .atomic) }
    }

    static func clear(_ storage: PageStorage = .standard) {
        try? FileManager.default.removeItem(at: storage.signatureURL)
    }
}
