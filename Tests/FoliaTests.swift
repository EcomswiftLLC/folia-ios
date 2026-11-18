import XCTest
import PDFKit
import UIKit
@testable import Folia

final class FoliaTests: XCTestCase {
    // MARK: helpers

    private func makeImage(width: Int, height: Int, text: String? = nil) -> CGImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 4))
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: CGFloat(height) * 0.16, weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
                (text as NSString).draw(at: CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.5), withAttributes: attributes)
            }
        }
        return image.cgImage!
    }

    private func tempStorage() -> PageStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folia-test-\(UUID().uuidString)", isDirectory: true)
        return PageStorage(root: root)
    }

    private func samplePDF(pages: Int) -> PDFDocument {
        let inputs = (0..<pages).map { PDFPageInput(image: makeImage(width: 600, height: 800, text: "Page \($0 + 1)")) }
        return PDFDocument(data: PDFBuilder.makePDF(inputs, pageSize: .a4))!
    }

    // MARK: ads gate

    func testRewardedPolicyOffersOnlyWithAdAndOutsideGrace() {
        var policy = RewardedPolicy()
        let now = Date()
        XCTAssertFalse(policy.shouldOffer(adReady: false, now: now))
        XCTAssertTrue(policy.shouldOffer(adReady: true, now: now))
        policy.didEarnReward(now: now)
        XCTAssertFalse(policy.shouldOffer(adReady: true, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldOffer(adReady: true, now: now.addingTimeInterval(300)))
    }

    func testRewardedPolicyWaitsForReloadOnlyAfterAnAdWasClosedEarly() {
        var policy = RewardedPolicy()
        let now = Date()
        XCTAssertFalse(policy.shouldWaitForReload(adReady: false, reloading: true, now: now), "nothing was closed early yet")
        policy.didCloseEarly(now: now)
        XCTAssertTrue(policy.shouldWaitForReload(adReady: false, reloading: true, now: now.addingTimeInterval(3)))
        XCTAssertFalse(policy.shouldWaitForReload(adReady: true, reloading: true, now: now.addingTimeInterval(3)), "an ad is ready: offer it")
        XCTAssertFalse(policy.shouldWaitForReload(adReady: false, reloading: false, now: now.addingTimeInterval(3)), "no reload in flight: the export runs")
        XCTAssertFalse(policy.shouldWaitForReload(adReady: false, reloading: true, now: now.addingTimeInterval(RewardedPolicy.earlyCloseWindow + 1)), "long after: the export runs")
        policy.didEarnReward(now: now.addingTimeInterval(10))
        XCTAssertFalse(policy.shouldWaitForReload(adReady: false, reloading: true, now: now.addingTimeInterval(11)), "a watched ad ends the wait")
        XCTAssertEqual(RewardedCancelReason.closedEarly.message, "Watch the whole ad to export.")
        XCTAssertEqual(RewardedPolicy.reloadWait, 6)
    }

    // MARK: scan engine

    func testQuadRules() {
        XCTAssertTrue(Quad.full.isFull)
        XCTAssertTrue(Quad.full.isUsable)
        let small = Quad(tl: CGPoint(x: 0.4, y: 0.4), tr: CGPoint(x: 0.5, y: 0.4), br: CGPoint(x: 0.5, y: 0.5), bl: CGPoint(x: 0.4, y: 0.5))
        XCTAssertFalse(small.isUsable, "a tiny area is not a page")
        let bowtie = Quad(tl: CGPoint(x: 0.1, y: 0.1), tr: CGPoint(x: 0.9, y: 0.9), br: CGPoint(x: 0.9, y: 0.1), bl: CGPoint(x: 0.1, y: 0.9))
        XCTAssertFalse(bowtie.isUsable, "crossed corners are not usable")
        let page = Quad(tl: CGPoint(x: 0.1, y: 0.1), tr: CGPoint(x: 0.9, y: 0.12), br: CGPoint(x: 0.88, y: 0.9), bl: CGPoint(x: 0.12, y: 0.88))
        XCTAssertTrue(page.isUsable)
        XCTAssertFalse(page.isFull)
    }

    func testRenderKeepsSizeAndTurnsSwapSides() {
        let cg = makeImage(width: 400, height: 200)
        let plain = PageRenderer.render(cg, filter: .original, quad: nil, quarterTurns: 0)
        XCTAssertEqual(plain?.width, 400)
        XCTAssertEqual(plain?.height, 200)
        let turned = PageRenderer.render(cg, filter: .original, quad: nil, quarterTurns: 1)
        XCTAssertEqual(turned?.width, 200)
        XCTAssertEqual(turned?.height, 400)
        let negative = PageRenderer.render(cg, filter: .original, quad: nil, quarterTurns: -1)
        XCTAssertEqual(negative?.width, 200)
    }

    func testEveryFilterProducesAnImageOfTheSameSize() {
        let cg = makeImage(width: 320, height: 240, text: "Folia")
        for filter in ScanFilter.allCases {
            let out = PageRenderer.render(cg, filter: filter, quad: nil, quarterTurns: 0)
            XCTAssertNotNil(out, "\(filter)")
            XCTAssertEqual(out?.width, 320, "\(filter)")
            XCTAssertEqual(out?.height, 240, "\(filter)")
        }
    }

    func testBlackAndWhiteMakesPaperWhite() {
        let cg = makeImage(width: 200, height: 200)
        guard let out = PageRenderer.render(cg, filter: .bw, quad: nil, quarterTurns: 0) else { return XCTFail("no image") }
        let provider = out.dataProvider!.data!
        let bytes = CFDataGetBytePtr(provider)!
        // Bottom right pixel is plain paper (0.93 grey): it should come out white.
        let offset = (out.height - 5) * out.bytesPerRow + (out.width - 5) * (out.bitsPerPixel / 8)
        XCTAssertGreaterThan(Int(bytes[offset]), 235)
    }

    func testPerspectiveCropShrinksPage() {
        let cg = makeImage(width: 800, height: 600)
        let quad = Quad(tl: CGPoint(x: 0.1, y: 0.1), tr: CGPoint(x: 0.9, y: 0.1), br: CGPoint(x: 0.9, y: 0.9), bl: CGPoint(x: 0.1, y: 0.9))
        let out = PageRenderer.render(cg, filter: .original, quad: quad, quarterTurns: 0)
        XCTAssertNotNil(out)
        XCTAssertLessThan(out!.width, 800)
        XCTAssertEqual(Double(out!.width) / Double(out!.height), 640.0 / 480.0, accuracy: 0.08)
    }

    func testMaxSideIsRespected() {
        let cg = makeImage(width: 1600, height: 1200)
        let out = PageRenderer.render(cg, filter: .auto, quad: nil, quarterTurns: 0, maxSide: 800)
        XCTAssertNotNil(out)
        XCTAssertLessThanOrEqual(max(out!.width, out!.height), 801)
    }

    func testTextRecognitionReadsLargeText() {
        let cg = makeImage(width: 1200, height: 800, text: "FOLIA SCAN")
        let lines = OCREngine.recognize(cg)
        let joined = OCREngine.plainText(lines).uppercased()
        XCTAssertTrue(joined.contains("FOLIA"), "recognised: \(joined)")
    }

    // MARK: PDF building

    func testPageSizes() {
        let a4 = PDFBuilder.pageSize(for: CGSize(width: 3000, height: 4000), option: .a4)
        XCTAssertEqual(a4.width, 595.2, accuracy: 0.5)
        let landscapeLetter = PDFBuilder.pageSize(for: CGSize(width: 4000, height: 3000), option: .letter)
        XCTAssertEqual(landscapeLetter.width, 792, accuracy: 0.5)
        let fit = PDFBuilder.pageSize(for: CGSize(width: 1000, height: 2000), option: .auto)
        XCTAssertEqual(fit.height, PDFBuilder.fitLongSide, accuracy: 1)
        XCTAssertEqual(fit.width / fit.height, 0.5, accuracy: 0.01)
    }

    func testMakePDFHasOnePagePerImage() {
        let doc = samplePDF(pages: 3)
        XCTAssertEqual(doc.pageCount, 3)
        let size = doc.page(at: 0)!.bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, 595.2, accuracy: 1)
    }

    func testSearchableTextLayerIsFoundByPDFKit() {
        let line = OCRLine(text: "Invoice 4821", x: 0.1, y: 0.7, w: 0.5, h: 0.05)
        let data = PDFBuilder.makePDF([PDFPageInput(image: makeImage(width: 600, height: 800), ocr: [line])], pageSize: .a4)
        let doc = PDFDocument(data: data)!
        XCTAssertTrue((doc.string ?? "").contains("Invoice 4821"), "text layer: \(doc.string ?? "nil")")
        XCTAssertFalse(doc.findString("4821", withOptions: .caseInsensitive).isEmpty)
    }

    func testStreamingBuilderSkipsMissingPages() {
        let built = PDFBuilder.makePDFReporting(count: 3) { index in
            index == 1 ? nil : PDFPageInput(image: self.makeImage(width: 300, height: 400))
        }
        XCTAssertEqual(PDFDocument(data: built.data)?.pageCount, 2)
        XCTAssertEqual(built.skipped, 1, "a page that could not be drawn is counted, not hidden")
        let all = PDFBuilder.makePDFReporting(count: 2) { _ in nil }
        XCTAssertEqual(all.skipped, 2)
    }

    // MARK: PDF operations

    func testMergeAndExtract() {
        let merged = PDFOps.merge([samplePDF(pages: 2), samplePDF(pages: 3)])
        XCTAssertEqual(merged.pageCount, 5)
        let part = PDFOps.extract(merged, pages: [4, 0, 99])
        XCTAssertEqual(part.pageCount, 2, "out of range pages are ignored")
    }

    func testPagesToImages() {
        let doc = samplePDF(pages: 2)
        let images = PDFOps.images(doc, maxSide: 900)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(max(images[0].width, images[0].height), 900)
        XCTAssertEqual(PDFOps.images(doc, pages: [1], maxSide: 400).count, 1)
    }

    func testCompressKeepsPagesAndShrinks() {
        let big = (0..<2).map { PDFPageInput(image: makeImage(width: 2400, height: 3200, text: "Big \($0)")) }
        let doc = PDFDocument(data: PDFBuilder.makePDF(big, pageSize: .a4, quality: 0.95))!
        let original = doc.dataRepresentation()?.count ?? 0
        guard let data = PDFOps.compress(doc, level: .tiny), let small = PDFDocument(data: data) else { return XCTFail("compress failed") }
        XCTAssertEqual(small.pageCount, 2)
        XCTAssertLessThan(data.count, original)
    }

    func testLockAndUnlock() {
        let doc = samplePDF(pages: 1)
        guard let locked = PDFOps.lock(doc, password: "secret1") else { return XCTFail("lock failed") }
        let reopened = PDFDocument(data: locked)!
        XCTAssertTrue(reopened.isLocked)
        XCTAssertFalse(reopened.unlock(withPassword: "wrong"))
        XCTAssertTrue(reopened.unlock(withPassword: "secret1"))
        guard let clean = PDFOps.render(reopened), let open = PDFDocument(data: clean) else { return XCTFail("unlock render failed") }
        XCTAssertFalse(open.isLocked)
        XCTAssertEqual(open.pageCount, 1)
    }

    func testOverlaysKeepPageCount() {
        let doc = samplePDF(pages: 3)
        let numbers = PDFOverlays.pageNumbers(total: 3, position: .bottomCenter, format: .pageOfTotal, start: 1, skipFirst: true, fontSize: 11, color: .darkGray)
        let numbered = PDFOps.render(doc, overlay: numbers)
        XCTAssertEqual(numbered.flatMap { PDFDocument(data: $0) }?.pageCount, 3)
        let mark = PDFOverlays.watermark(text: "DRAFT", color: .red, opacity: 0.2, sizeFraction: 0.2, angleDegrees: -35)
        XCTAssertNotNil(PDFOps.render(doc, overlay: mark))
        let item = PagePlacement(pageIndex: 0, content: .text("Signed", size: 18, color: .black), center: CGPoint(x: 0.5, y: 0.5), width: 0.2)
        XCTAssertNotNil(PDFOps.render(doc, overlay: PDFOverlays.placements([item])))
    }

    func testPageNumberFormats() {
        XCTAssertEqual(NumberFormat.plain.text(number: 3, total: 12), "3")
        XCTAssertEqual(NumberFormat.page.text(number: 3, total: 12), "Page 3")
        XCTAssertEqual(NumberFormat.ofTotal.text(number: 3, total: 12), "3 / 12")
        XCTAssertEqual(NumberFormat.pageOfTotal.text(number: 3, total: 12), "Page 3 of 12")
    }

    func testIDCardSheetIsAPage() {
        let front = makeImage(width: 856, height: 540, text: "ID")
        guard let sheet = IDCardComposer.compose(front: front, back: front, page: .a4) else { return XCTFail("no sheet") }
        XCTAssertEqual(sheet.width, 1654, accuracy: 3)
        XCTAssertEqual(sheet.height, 2339, accuracy: 3)
    }

    // MARK: files

    func testSafeNames() {
        XCTAssertEqual(ExportFile.safeName("Rent / lease: 2026?"), "Rent lease 2026")
        XCTAssertEqual(ExportFile.safeName("  "), "Scan")
        XCTAssertEqual(ExportFile.safeName("a/b", fallback: "X"), "a b")
        XCTAssertLessThanOrEqual(ExportFile.safeName(String(repeating: "x", count: 300)).count, 80)
    }

    func testExportFileTemporaryURLRoundTrips() throws {
        let file = ExportFile(data: Data("hello".utf8), filename: "hello.txt", kind: .text)
        let url = try XCTUnwrap(file.temporaryURL())
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
        ExportFile.cleanTemporary()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveTemporaryDeletesOnlyExportCopies() throws {
        let file = ExportFile(data: Data("hello".utf8), filename: "hello.txt", kind: .text)
        let first = try XCTUnwrap(file.temporaryURL())
        let second = try XCTUnwrap(file.temporaryURL())
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent(), "every copy has its own folder")
        ExportFile.removeTemporary([first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "another copy that is still in use stays")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("folia-outside-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside)
        ExportFile.removeTemporary([outside])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "files outside the export folder are never removed")
        try? FileManager.default.removeItem(at: outside)
        ExportFile.removeTemporary([second])
    }

    // MARK: store

    @MainActor
    func testStoreAddEditDeleteAndReload() throws {
        let storage = tempStorage()
        let store = DocStore(storage: storage)
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 600, height: 800), detect: false))
        let id = try XCTUnwrap(store.insert([source, source], title: "Lease"))
        XCTAssertEqual(store.docs.count, 1)
        XCTAssertEqual(store.doc(id)?.pages.count, 2)
        XCTAssertFalse(store.doc(id)!.autoTitle)

        let pageID = store.doc(id)!.pages[0].id
        store.updatePage(id, pageID) { $0.ocr = [OCRLine(text: "hello", x: 0, y: 0, w: 1, h: 1)] }
        XCTAssertEqual(store.page(id, pageID)?.version, 1)
        XCTAssertNotNil(store.page(id, pageID)?.ocr, "a filter or text change keeps recognised text")
        store.rotate(id, pageID, by: 1)
        XCTAssertEqual(store.page(id, pageID)?.quarterTurns, 1)
        XCTAssertNil(store.page(id, pageID)?.ocr, "rotating clears recognised text")
        store.rotate(id, pageID, by: -2)
        XCTAssertEqual(store.page(id, pageID)?.quarterTurns, 3)

        store.movePages(id, from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(store.doc(id)?.pages.last?.id, pageID)

        let again = DocStore(storage: storage)
        XCTAssertEqual(again.docs.count, 1, "the library is saved to disk")
        XCTAssertEqual(again.doc(id)?.pages.count, 2)

        store.deletePage(id, pageID)
        XCTAssertEqual(store.doc(id)?.pages.count, 1)
        let last = store.doc(id)!.pages[0].id
        store.deletePage(id, last)
        XCTAssertNil(store.doc(id), "removing the last page removes the document")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.pagesDirectory.path)) ?? []
        XCTAssertTrue(files.isEmpty, "page files are removed from disk")
    }

    @MainActor
    func testStoreAppendDuplicateCombineAndRename() throws {
        let store = DocStore(storage: tempStorage())
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        let first = try XCTUnwrap(store.insert([source], title: "One"))
        let second = try XCTUnwrap(store.insert([source, source], title: "Two"))
        XCTAssertEqual(store.insert([source], into: first), first)
        XCTAssertEqual(store.doc(first)?.pages.count, 2)
        let copy = try XCTUnwrap(store.duplicate(first))
        XCTAssertEqual(store.doc(copy)?.title, "One copy")
        XCTAssertNotEqual(store.doc(copy)?.pages.first?.id, store.doc(first)?.pages.first?.id)
        let merged = try XCTUnwrap(store.combine([first, second], title: "Both"))
        XCTAssertEqual(store.doc(merged)?.pages.count, 4)
        store.rename(merged, to: "  Final  ")
        XCTAssertEqual(store.doc(merged)?.title, "Final")
        store.rename(merged, to: "   ")
        XCTAssertEqual(store.doc(merged)?.title, "Final", "an empty name is ignored")
        store.deleteDoc(copy)
        XCTAssertNil(store.doc(copy))
    }

    @MainActor
    func testSearchAndAutoTitle() throws {
        let store = DocStore(storage: tempStorage())
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        let id = try XCTUnwrap(store.insert([source]))
        XCTAssertTrue(store.doc(id)!.autoTitle)
        XCTAssertTrue(store.doc(id)!.title.hasPrefix("Scan "))
        let pageID = store.doc(id)!.pages[0].id
        store.updatePage(id, pageID) { $0.ocr = [OCRLine(text: "Café Receipt", x: 0, y: 0.9, w: 0.5, h: 0.05)] }
        XCTAssertTrue(DocStore.matches(store.doc(id)!, query: "cafe"), "search ignores case and accents")
        XCTAssertTrue(DocStore.matches(store.doc(id)!, query: "  "))
        XCTAssertFalse(DocStore.matches(store.doc(id)!, query: "invoice"))
        XCTAssertEqual(DocStore.suggestedTitle(from: [OCRLine(text: "12", x: 0, y: 0, w: 0, h: 0), OCRLine(text: "Rental Agreement", x: 0, y: 0, w: 0, h: 0)]), "Rental Agreement")
        XCTAssertNil(DocStore.suggestedTitle(from: [OCRLine(text: "1 2 3", x: 0, y: 0, w: 0, h: 0)]))
    }

    @MainActor
    func testExportBuilderMakesPDFAndImages() throws {
        let storage = tempStorage()
        let store = DocStore(storage: storage)
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 900, height: 1200, text: "Hello"), detect: false))
        let id = try XCTUnwrap(store.insert([source, source], title: "Export test"))
        let doc = try XCTUnwrap(store.doc(id))
        var options = ExportOptions()
        options.quality = .small
        let pdf = try XCTUnwrap(ExportBuilder.pdf(doc: doc, storage: storage, options: options))
        XCTAssertEqual(pdf.filename, "Export test.pdf")
        XCTAssertEqual(pdf.skippedPages, 0)
        XCTAssertEqual(PDFDocument(data: pdf.data)?.pageCount, 2)
        let images = ExportBuilder.images(doc: doc, storage: storage, options: options, format: .jpeg)
        XCTAssertEqual(images.map(\.filename), ["Export test-1.jpg", "Export test-2.jpg"])
        XCTAssertNil(ExportBuilder.text(doc: doc), "no text before recognition")
    }

    @MainActor
    func testExportReportsPagesThatCouldNotBeDrawn() throws {
        let storage = tempStorage()
        let store = DocStore(storage: storage)
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 600, height: 800), detect: false))
        let id = try XCTUnwrap(store.insert([source, source, source], title: "Gap"))
        let doc = try XCTUnwrap(store.doc(id))
        var options = ExportOptions()
        options.quality = .small
        try FileManager.default.removeItem(at: storage.sourceURL(doc.pages[1].id))
        let partial = try XCTUnwrap(ExportBuilder.pdf(doc: doc, storage: storage, options: options))
        XCTAssertEqual(partial.skippedPages, 1, "the missing page is reported instead of silently dropped")
        XCTAssertEqual(PDFDocument(data: partial.data)?.pageCount, 2)
        XCTAssertEqual(ExportBuilder.images(doc: doc, storage: storage, options: options, format: .jpeg).count, 2)
        for page in doc.pages { try? FileManager.default.removeItem(at: storage.sourceURL(page.id)) }
        XCTAssertNil(ExportBuilder.pdf(doc: doc, storage: storage, options: options), "a PDF with no pages is not a result")
    }

    @MainActor
    func testRecognizeTextFillsPagesAndTitle() async throws {
        let store = DocStore(storage: tempStorage())
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 1200, height: 1600, text: "RENTAL AGREEMENT"), detect: false))
        let id = try XCTUnwrap(store.insert([source]))
        await store.recognizeText(docID: id)
        let page = try XCTUnwrap(store.doc(id)?.pages.first)
        XCTAssertNotNil(page.ocr)
        XCTAssertTrue(OCREngine.plainText(page.ocr ?? []).uppercased().contains("RENTAL"))
        XCTAssertFalse(store.doc(id)!.title.hasPrefix("Scan "), "the first line of text becomes the title")
    }

    // MARK: library file

    func testRecordsDecodeWithMissingFieldsAndUnknownFilter() throws {
        let pageID = UUID()
        let json = """
        [{"title": "Old lease", "pages": [{"id": "\(pageID.uuidString)", "filter": "sepia"}, {"id": 42}]}]
        """
        let docs = try JSONDecoder().decode([DocRecord].self, from: Data(json.utf8))
        XCTAssertEqual(docs.count, 1)
        let doc = docs[0]
        XCTAssertEqual(doc.title, "Old lease")
        XCTAssertFalse(doc.autoTitle)
        XCTAssertEqual(doc.pages.count, 2, "a damaged field falls back to its default instead of dropping the page")
        let page = doc.pages[0]
        XCTAssertEqual(page.id, pageID)
        XCTAssertEqual(page.filter, .auto, "an unknown look falls back to Auto")
        XCTAssertNil(page.quad)
        XCTAssertNil(page.ocr)
        XCTAssertEqual(page.quarterTurns, 0)
        XCTAssertEqual(page.version, 0)

        let empty = try JSONDecoder().decode(PageRecord.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.filter, .auto)
        let roundTrip = try JSONDecoder().decode([DocRecord].self, from: JSONEncoder().encode(docs))
        XCTAssertEqual(roundTrip, docs)
    }

    @MainActor
    func testCorruptLibraryIsPreservedAndPageFilesKept() throws {
        let storage = tempStorage()
        storage.prepare()
        let damaged = Data("{ this is not a library".utf8)
        try damaged.write(to: storage.indexURL)
        let pageFile = storage.sourceURL(UUID())
        try Data("jpeg".utf8).write(to: pageFile)

        let store = DocStore(storage: storage)
        XCTAssertTrue(store.docs.isEmpty)
        XCTAssertTrue(store.indexWasDamaged)
        let preserved = storage.root.appendingPathComponent(DocStore.corruptIndexName)
        XCTAssertEqual(try Data(contentsOf: preserved), damaged, "the damaged file is kept as library.corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageFile.path), "page files of the damaged library are not removed")

        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        XCTAssertNotNil(store.insert([source], title: "Fresh"))
        XCTAssertTrue(store.lastSaveSucceeded)
        XCTAssertEqual(try Data(contentsOf: preserved), damaged, "saving a new library never overwrites the preserved copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageFile.path), "no clean-up in the session that found the damage")
        XCTAssertEqual(DocStore(storage: storage).docs.map(\.title), ["Fresh"])
    }

    @MainActor
    func testPageWithUnreadableIdIsDamageAndItsFileIsKept() throws {
        let storage = tempStorage()
        storage.prepare()
        let pageFile = storage.sourceURL(UUID())
        try Data("jpeg".utf8).write(to: pageFile)
        let json = #"[{"title": "Lease", "pages": [{"id": 42}]}]"#
        try Data(json.utf8).write(to: storage.indexURL)
        XCTAssertEqual(LibraryAudit.unreadablePages(in: Data(json.utf8)), 1)
        XCTAssertEqual(LibraryAudit.unreadablePages(in: Data(#"[{"title": "Ok", "pages": [{"id": "\#(UUID().uuidString)"}]}]"#.utf8)), 0)

        let store = DocStore(storage: storage)
        XCTAssertEqual(store.docs.count, 1)
        XCTAssertTrue(store.indexWasDamaged, "a page whose id cannot be read is damage")
        XCTAssertEqual(store.libraryProblem, .damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageFile.path), "its picture file is not cleaned up as an orphan")

        // Saving over the damaged library, then starting again, must not clean the file up either.
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        XCTAssertNotNil(store.insert([source], title: "New"))
        let again = DocStore(storage: storage)
        XCTAssertFalse(again.indexWasDamaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageFile.path), "a preserved copy of the damaged library exists, so no clean-up")
    }

    @MainActor
    func testInsertReportsPagesThatCouldNotBeWritten() throws {
        let storage = tempStorage()
        let store = DocStore(storage: storage)
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        // A file where the Pages folder should be: no page can be written.
        try FileManager.default.removeItem(at: storage.pagesDirectory)
        try Data("x".utf8).write(to: storage.pagesDirectory)
        let result = store.insertReporting([source, source], title: "Full")
        XCTAssertNil(result.docID)
        XCTAssertEqual(result.stored, 0)
        XCTAssertEqual(result.failed, 2, "failed pages are counted, not dropped silently")
        XCTAssertTrue(store.docs.isEmpty)
        XCTAssertNil(store.insert([source]))
    }

    @MainActor
    func testFailedSaveIsReportedAndCanBeRetried() throws {
        let storage = tempStorage()
        let store = DocStore(storage: storage)
        XCTAssertNil(store.libraryProblem)
        let source = try XCTUnwrap(ScanImporter.makeSource(makeImage(width: 300, height: 400), detect: false))
        // A read-only app folder: the page file (in its own sub folder) can be written, the library file cannot.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storage.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path) }
        XCTAssertNotNil(store.insert([source], title: "Unsaved"))
        XCTAssertFalse(store.lastSaveSucceeded)
        XCTAssertEqual(store.libraryProblem, .saveFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path)
        store.retrySave()
        XCTAssertTrue(store.lastSaveSucceeded)
        XCTAssertNil(store.libraryProblem)
        XCTAssertEqual(DocStore(storage: storage).docs.map(\.title), ["Unsaved"])
    }

    @MainActor
    func testImportPDFAddsPagesInBatches() async throws {
        let store = DocStore(storage: tempStorage())
        let doc = samplePDF(pages: 5)
        // No text recognition here: it would keep running in the background while the next tests start.
        let result = await store.importPDF(doc, title: "Batches", batchSize: 2, readText: false)
        XCTAssertEqual(result.stored, 5)
        XCTAssertEqual(result.failed, 0)
        let id = try XCTUnwrap(result.docID)
        XCTAssertEqual(store.doc(id)?.pages.count, 5, "every batch lands in the same document")
        XCTAssertEqual(store.doc(id)?.title, "Batches")
        let more = await store.importPDF(doc, into: id, batchSize: 3, readText: false)
        XCTAssertEqual(more.docID, id)
        XCTAssertEqual(store.doc(id)?.pages.count, 10)
        XCTAssertEqual(ScanImporter.makeSources(pdf: doc, pages: [1, 3], maxSide: 600).count, 2)
    }

    // MARK: confirmations and tool runs

    func testPageDeletionWordingWarnsAboutTheLastPage() {
        let one = PageDeletion.wording(deleting: 1, of: 4)
        XCTAssertFalse(one.removesDocument)
        XCTAssertEqual(one.title, "Delete this page?")
        XCTAssertEqual(PageDeletion.wording(deleting: 2, of: 4).title, "Delete 2 pages?")
        let last = PageDeletion.wording(deleting: 1, of: 1)
        XCTAssertTrue(last.removesDocument)
        XCTAssertTrue(last.message.contains("whole document"))
        XCTAssertTrue(PageDeletion.wording(deleting: 3, of: 3).removesDocument, "taking out every page removes the document too")
    }

    private func slowWork(_ name: String, delay: TimeInterval) -> () -> [ExportFile]? {
        {
            Thread.sleep(forTimeInterval: delay)
            return [ExportFile(data: Data(name.utf8), filename: name, kind: .text)]
        }
    }

    @MainActor
    func testToolRunnerIgnoresRunsThatWereSupersededOrReset() async {
        let runner = ToolRunner()
        // An option changes while a run is in progress: its result must never show up.
        let stale = Task { await runner.run(self.slowWork("stale.txt", delay: 0.5)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        runner.reset()
        XCTAssertFalse(runner.working, "reset ends the spinner")
        await stale.value
        XCTAssertTrue(runner.files.isEmpty, "the result of a reset run is dropped")
        XCTAssertNil(runner.error)

        // A newer run finishes first; the older one finishing later must not replace it.
        let slow = Task { await runner.run(self.slowWork("slow.txt", delay: 0.5)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await runner.run(slowWork("fast.txt", delay: 0))
        await slow.value
        XCTAssertEqual(runner.files.map(\.filename), ["fast.txt"])
        XCTAssertFalse(runner.working)
    }

    // MARK: pages as displayed (rotation and crop box)

    private func pdfData(size: CGSize, draw: (CGContext) -> Void) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            draw(context.cgContext)
        }
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let o = (y * image.width + x) * 4
        let (r, g, b) = (Int(buffer[o]), Int(buffer[o + 1]), Int(buffer[o + 2]))
        if r > 200 && g < 90 && b < 90 { return "red" }
        if g > 150 && r < 90 && b < 90 { return "green" }
        if b > 200 && r < 90 && g < 90 { return "blue" }
        if r > 235 && g > 235 && b > 235 { return "white" }
        return "rgb(\(r),\(g),\(b))"
    }

    private func layout(_ image: CGImage) -> String {
        let w = image.width, h = image.height
        let (left, right, top, bottom) = (w / 4, w * 3 / 4, h / 8, h * 7 / 8)
        return "\(w)x\(h) topLeft=\(pixel(image, left, top)) topRight=\(pixel(image, right, top)) bottomLeft=\(pixel(image, left, bottom)) bottomRight=\(pixel(image, right, bottom))"
    }

    func testRotatedPageIsDrawnAsDisplayed() throws {
        // A landscape page (400 x 200) with a red square in its top left corner.
        let data = pdfData(size: CGSize(width: 400, height: 200)) { cg in
            cg.setFillColor(UIColor.red.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(doc.page(at: 0))
        page.rotation = 90
        let size = PDFOps.pageSize(page)
        XCTAssertEqual(size.width, 200, accuracy: 0.5)
        XCTAssertEqual(size.height, 400, accuracy: 0.5)

        // Turned a quarter clockwise, the top left corner is now the top right corner.
        let image = try XCTUnwrap(PDFOps.images(doc, maxSide: 400).first)
        XCTAssertEqual(layout(image), "200x400 topLeft=white topRight=red bottomLeft=white bottomRight=white", "rendered picture")

        // The same page redrawn into a new PDF keeps its look.
        let redrawn = try XCTUnwrap(PDFOps.render(doc))
        let copy = try XCTUnwrap(PDFDocument(data: redrawn))
        let copyPage = try XCTUnwrap(copy.page(at: 0))
        XCTAssertEqual(PDFOps.pageSize(copyPage).width, 200, accuracy: 0.5)
        XCTAssertEqual(PDFOps.pageSize(copyPage).height, 400, accuracy: 0.5)
        let copyImage = try XCTUnwrap(PDFOps.images(copy, maxSide: 400).first)
        XCTAssertEqual(layout(copyImage), "200x400 topLeft=white topRight=red bottomLeft=white bottomRight=white", "re-rendered PDF")
    }

    func testCropBoxDecidesWhatIsDrawn() throws {
        // 400 x 400 page: blue in the top left, red and green inside the visible area.
        let data = pdfData(size: CGSize(width: 400, height: 400)) { cg in
            cg.setFillColor(UIColor.blue.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            cg.setFillColor(UIColor.red.cgColor)
            cg.fill(CGRect(x: 100, y: 100, width: 100, height: 100))
            cg.setFillColor(UIColor(red: 0, green: 0.8, blue: 0, alpha: 1).cgColor)
            cg.fill(CGRect(x: 200, y: 0, width: 100, height: 100))
        }
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(doc.page(at: 0))
        // Viewers show only this part: x 100 to 300, and the top 200 points (PDF coordinates start at the bottom).
        page.setBounds(CGRect(x: 100, y: 200, width: 200, height: 200), for: .cropBox)
        let size = PDFOps.pageSize(page)
        XCTAssertEqual(size.width, 200, accuracy: 0.5)
        XCTAssertEqual(size.height, 200, accuracy: 0.5)

        let expected = "200x200 topLeft=white topRight=green bottomLeft=red bottomRight=white"
        let image = try XCTUnwrap(PDFOps.images(doc, maxSide: 200).first)
        XCTAssertEqual(layout(image), expected, "rendered picture")

        let redrawn = try XCTUnwrap(PDFOps.render(doc))
        let copy = try XCTUnwrap(PDFDocument(data: redrawn))
        let copyImage = try XCTUnwrap(PDFOps.images(copy, maxSide: 200).first)
        XCTAssertEqual(layout(copyImage), expected, "re-rendered PDF")
    }
}
