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
        let data = PDFBuilder.makePDF(count: 3) { index in
            index == 1 ? nil : PDFPageInput(image: self.makeImage(width: 300, height: 400))
        }
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 2)
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
        let pdf = ExportBuilder.pdf(doc: doc, storage: storage, options: options)
        XCTAssertEqual(pdf.filename, "Export test.pdf")
        XCTAssertEqual(PDFDocument(data: pdf.data)?.pageCount, 2)
        let images = ExportBuilder.images(doc: doc, storage: storage, options: options, format: .jpeg)
        XCTAssertEqual(images.map(\.filename), ["Export test-1.jpg", "Export test-2.jpg"])
        XCTAssertNil(ExportBuilder.text(doc: doc), "no text before recognition")
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
}
