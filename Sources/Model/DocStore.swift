import SwiftUI
import UIKit
import ImageIO

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
    @discardableResult
    func insert(_ sources: [ScanImporter.Source], title: String? = nil, into docID: UUID? = nil, filter: ScanFilter = FoliaPrefs.defaultFilter) -> UUID? {
        guard !sources.isEmpty else { return nil }
        var pages: [PageRecord] = []
        for source in sources {
            var page = PageRecord()
            page.filter = filter
            page.quad = source.quad
            do {
                try source.data.write(to: storage.sourceURL(page.id), options: .atomic)
                pages.append(page)
            } catch {
                continue
            }
        }
        guard !pages.isEmpty else { return nil }
        if let docID, let index = docs.firstIndex(where: { $0.id == docID }) {
            docs[index].pages.append(contentsOf: pages)
            docs[index].modifiedAt = Date()
            save()
            return docID
        }
        var record = DocRecord(title: title ?? Self.defaultTitle())
        record.autoTitle = title == nil
        record.pages = pages
        docs.insert(record, at: 0)
        save()
        return record.id
    }

    /// Reads pictures off the main thread, then stores them.
    func importImages(_ images: [CGImage], detect: Bool, into docID: UUID? = nil, title: String? = nil) async -> UUID? {
        let sources: [ScanImporter.Source] = await Task.detached(priority: .userInitiated) {
            images.compactMap { ScanImporter.makeSource($0, detect: detect) }
        }.value
        let id = insert(sources, title: title, into: docID)
        if let id { Task { await self.recognizeText(docID: id) } }
        return id
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
        if after.quad != before.quad || after.quarterTurns != before.quarterTurns { after.ocr = nil }
        after.version = before.version + 1
        docs[d].pages[p] = after
        docs[d].modifiedAt = Date()
        save()
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
            let snapshot = page
            let lines: [OCRLine] = await Task.detached(priority: .utility) {
                guard let image = storage.render(snapshot, maxSide: 2000) else { return [] }
                return OCREngine.recognize(image)
            }.value
            setOCR(docID, pageID: page.id, lines: lines, expectedVersion: snapshot.version)
        }
        applyAutoTitle(docID)
    }

    private func setOCR(_ docID: UUID, pageID: UUID, lines: [OCRLine], expectedVersion: Int) {
        guard let d = docs.firstIndex(where: { $0.id == docID }),
              let p = docs[d].pages.firstIndex(where: { $0.id == pageID }) else { return }
        // The page was edited while text was being read: its geometry may have changed, so drop this result.
        // The next call reads it again.
        guard docs[d].pages[p].version == expectedVersion else { return }
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

    private func load() {
        guard let data = try? Data(contentsOf: storage.indexURL),
              let decoded = try? JSONDecoder().decode([DocRecord].self, from: data) else { return }
        docs = decoded
        removeOrphans()
    }

    private func removeOrphans() {
        let used = Set(docs.flatMap { $0.pages.map { "\($0.id.uuidString).jpg" } })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.pagesDirectory.path)) ?? []
        for name in files where name.hasSuffix(".jpg") && !used.contains(name) {
            try? FileManager.default.removeItem(at: storage.pagesDirectory.appendingPathComponent(name))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(docs) else { return }
        try? data.write(to: storage.indexURL, options: .atomic)
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
