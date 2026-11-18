import UIKit
import PDFKit

// MARK: - Page sizes

enum PageSizeOption: String, CaseIterable, Identifiable {
    case auto, a4, letter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Fit scan"
        case .a4: return "A4"
        case .letter: return "US Letter"
        }
    }
}

struct PDFPageInput {
    var image: CGImage
    var ocr: [OCRLine]? = nil
}

// MARK: - Building PDFs from page images

enum PDFBuilder {
    static let a4 = CGSize(width: 595.2, height: 841.8)
    static let letter = CGSize(width: 612, height: 792)
    /// Long side of a "fit scan" page, in points (about A4).
    static let fitLongSide: CGFloat = 841.8

    static func pageSize(for image: CGSize, option: PageSizeOption) -> CGSize {
        let w = max(1, image.width), h = max(1, image.height)
        let landscape = w > h
        switch option {
        case .auto:
            let scale = fitLongSide / max(w, h)
            return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        case .a4:
            return landscape ? CGSize(width: a4.height, height: a4.width) : a4
        case .letter:
            return landscape ? CGSize(width: letter.height, height: letter.width) : letter
        }
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// A JPEG-backed copy so the PDF stores compressed image data instead of raw pixels.
    static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage? {
        guard let data = ImageCodec.encode(image, format: .jpeg, quality: quality),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// One image per page. Pages that have recognised text get an invisible text layer, so the PDF can be searched and selected.
    static func makePDF(
        _ pages: [PDFPageInput],
        pageSize option: PageSizeOption = .auto,
        margin: CGFloat = 0,
        quality: Double = 0.82,
        title: String = "Scan"
    ) -> Data {
        makePDF(count: pages.count, pageSize: option, margin: margin, quality: quality, title: title) { pages[$0] }
    }

    /// Same, but pages are produced one at a time, so a long document never holds every bitmap in memory at once.
    static func makePDF(
        count: Int,
        pageSize option: PageSizeOption = .auto,
        margin: CGFloat = 0,
        quality: Double = 0.82,
        title: String = "Scan",
        provider: (Int) -> PDFPageInput?
    ) -> Data {
        makePDFReporting(count: count, pageSize: option, margin: margin, quality: quality, title: title, provider: provider).data
    }

    /// Same, and also counts the pages the provider could not produce (they are left out of the PDF).
    static func makePDFReporting(
        count: Int,
        pageSize option: PageSizeOption = .auto,
        margin: CGFloat = 0,
        quality: Double = 0.82,
        title: String = "Scan",
        provider: (Int) -> PDFPageInput?
    ) -> (data: Data, skipped: Int) {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Folia",
            kCGPDFContextTitle as String: title,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4), format: format)
        var skipped = 0
        let data = renderer.pdfData { context in
            for index in 0..<count {
                autoreleasepool {
                    guard let input = provider(index) else { skipped += 1; return }
                    let image = input.image
                    let size = pageSize(for: CGSize(width: image.width, height: image.height), option: option)
                    let page = CGRect(origin: .zero, size: size)
                    context.beginPage(withBounds: page, pageInfo: [:])
                    let box = option == .auto && margin == 0 ? page : page.insetBy(dx: margin, dy: margin)
                    let drawRect = aspectFit(CGSize(width: image.width, height: image.height), in: box)
                    let embedded = jpegBacked(image, quality: quality) ?? image
                    UIImage(cgImage: embedded).draw(in: drawRect)
                    if let lines = input.ocr, !lines.isEmpty {
                        drawInvisibleText(lines, in: drawRect, context: context.cgContext)
                    }
                }
            }
        }
        return (data, skipped)
    }

    /// Text drawn fully transparent: it is not visible, but PDF readers can search, select and copy it.
    private static func drawInvisibleText(_ lines: [OCRLine], in rect: CGRect, context: CGContext) {
        for line in lines {
            let box = CGRect(
                x: rect.minX + CGFloat(line.x) * rect.width,
                y: rect.minY + CGFloat(1 - line.y - line.h) * rect.height,
                width: CGFloat(line.w) * rect.width,
                height: CGFloat(line.h) * rect.height
            )
            guard box.width > 1, box.height > 1 else { continue }
            let font = UIFont.systemFont(ofSize: max(4, box.height * 0.85))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.clear]
            let natural = (line.text as NSString).size(withAttributes: attributes)
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + (box.height - natural.height) / 2)
            context.scaleBy(x: box.width / max(1, natural.width), y: 1)
            (line.text as NSString).draw(at: .zero, withAttributes: attributes)
            context.restoreGState()
        }
    }
}

// MARK: - Working with existing PDFs

enum PDFOps {
    static func open(_ data: Data) -> PDFDocument? { PDFDocument(data: data) }

    static func open(url: URL) -> PDFDocument? { PDFDocument(url: url) }

    static func copyOfPage(_ doc: PDFDocument, _ index: Int) -> PDFPage? {
        guard index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { return nil }
        return page.copy() as? PDFPage
    }

    /// Joins documents in order.
    static func merge(_ docs: [PDFDocument]) -> PDFDocument {
        let out = PDFDocument()
        for doc in docs {
            for i in 0..<doc.pageCount {
                if let page = copyOfPage(doc, i) { out.insert(page, at: out.pageCount) }
            }
        }
        return out
    }

    /// A new document with only the chosen pages, in the order given.
    static func extract(_ doc: PDFDocument, pages: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for index in pages {
            if let page = copyOfPage(doc, index) { out.insert(page, at: out.pageCount) }
        }
        return out
    }

    /// The box viewers show: the crop box (which is the media box when no crop box is set). Every drawing and size
    /// calculation below uses this one box, so a page is never drawn with margins that viewers hide.
    static let displayBox: PDFDisplayBox = .cropBox

    /// The size of the page as it is displayed, in points: the display box with the page's rotation applied.
    static func pageSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: displayBox)
        let turned = abs(page.rotation) % 180 == 90
        return turned ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Draws every page again, with extra drawing on top. The original page content stays vector, so text remains text.
    /// `overlay` draws in UIKit coordinates (origin top left, points) on a page of the given size.
    static func render(_ doc: PDFDocument, overlay: ((Int, CGSize, CGContext) -> Void)? = nil) -> Data? {
        guard doc.pageCount > 0, let first = doc.page(at: 0) else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize(first)))
        return renderer.pdfData { context in
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let size = pageSize(page)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState()
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: displayBox, to: cg)
                cg.restoreGState()
                overlay?(i, size, cg)
            }
        }
    }

    /// Pages as pictures, longest side at most `maxSide` pixels.
    static func images(_ doc: PDFDocument, pages: [Int]? = nil, maxSide: CGFloat = 2000) -> [CGImage] {
        let indices = pages ?? Array(0..<doc.pageCount)
        var result: [CGImage] = []
        for index in indices {
            guard let page = doc.page(at: index) else { continue }
            autoreleasepool {
                let size = pageSize(page)
                let scale = min(maxSide / max(size.width, size.height), 4)
                let pixel = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: pixel, format: format).image { context in
                    let cg = context.cgContext
                    UIColor.white.setFill()
                    cg.fill(CGRect(origin: .zero, size: pixel))
                    cg.translateBy(x: 0, y: pixel.height)
                    cg.scaleBy(x: scale, y: -scale)
                    page.draw(with: displayBox, to: cg)
                }
                if let cgImage = image.cgImage { result.append(cgImage) }
            }
        }
        return result
    }

    /// Smaller file: every page becomes a JPEG at the chosen size and quality. Text is no longer selectable afterwards.
    static func compress(_ doc: PDFDocument, level: CompressionLevel) -> Data? {
        guard doc.pageCount > 0 else { return nil }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Folia"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        return renderer.pdfData { context in
            for i in 0..<doc.pageCount {
                autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let size = pageSize(page)
                    context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                    let pictures = images(doc, pages: [i], maxSide: level.maxSide)
                    guard let picture = pictures.first else { return }
                    let embedded = PDFBuilder.jpegBacked(picture, quality: level.quality) ?? picture
                    UIImage(cgImage: embedded).draw(in: CGRect(origin: .zero, size: size))
                }
            }
        }
    }

    /// Password-protected copy. Anyone opening it needs the password.
    static func lock(_ doc: PDFDocument, password: String) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard doc.write(to: url, withOptions: options) else { return nil }
        return try? Data(contentsOf: url)
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case high, medium, low, tiny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "Best quality"
        case .medium: return "Balanced"
        case .low: return "Small"
        case .tiny: return "Smallest"
        }
    }

    var detail: String {
        switch self {
        case .high: return "Sharp text, good for printing"
        case .medium: return "Good for email and sharing"
        case .low: return "Readable on screen"
        case .tiny: return "For strict upload limits"
        }
    }

    var maxSide: CGFloat {
        switch self {
        case .high: return 2400
        case .medium: return 1700
        case .low: return 1200
        case .tiny: return 900
        }
    }

    var quality: Double {
        switch self {
        case .high: return 0.8
        case .medium: return 0.65
        case .low: return 0.5
        case .tiny: return 0.4
        }
    }
}

// MARK: - Overlays: page numbers, watermark, signatures and text

enum NumberPosition: String, CaseIterable, Identifiable {
    case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomCenter: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topCenter: return "Top centre"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }
}

enum NumberFormat: String, CaseIterable, Identifiable {
    case plain, page, ofTotal, pageOfTotal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "3"
        case .page: return "Page 3"
        case .ofTotal: return "3 / 12"
        case .pageOfTotal: return "Page 3 of 12"
        }
    }

    func text(number: Int, total: Int) -> String {
        switch self {
        case .plain: return "\(number)"
        case .page: return "Page \(number)"
        case .ofTotal: return "\(number) / \(total)"
        case .pageOfTotal: return "Page \(number) of \(total)"
        }
    }
}

/// An item placed on a page. `center` is where its middle sits, as a fraction of the page (origin top left).
struct PagePlacement: Identifiable {
    enum Content {
        case text(String, size: CGFloat, color: UIColor)
        case image(UIImage)
    }

    let id = UUID()
    var pageIndex: Int
    var content: Content
    var center: CGPoint
    /// Width as a fraction of the page width. Text ignores this and uses its font size.
    var width: CGFloat
}

enum PDFOverlays {
    static func pageNumbers(
        total: Int, position: NumberPosition, format: NumberFormat,
        start: Int, skipFirst: Bool, fontSize: CGFloat, color: UIColor
    ) -> (Int, CGSize, CGContext) -> Void {
        return { index, size, _ in
            if skipFirst && index == 0 { return }
            let number = start + index - (skipFirst ? 1 : 0)
            let text = format.text(number: number, total: total - (skipFirst ? 1 : 0) + start - 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color]
            let textSize = text.size(withAttributes: attributes)
            let margin: CGFloat = 28
            var x: CGFloat
            switch position {
            case .bottomLeft, .topLeft: x = margin
            case .bottomRight, .topRight: x = size.width - margin - textSize.width
            default: x = (size.width - textSize.width) / 2
            }
            let y: CGFloat
            switch position {
            case .topLeft, .topCenter, .topRight: y = margin - textSize.height / 2
            default: y = size.height - margin - textSize.height / 2
            }
            text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }
    }

    static func watermark(
        text: String, color: UIColor, opacity: CGFloat, sizeFraction: CGFloat, angleDegrees: CGFloat
    ) -> (Int, CGSize, CGContext) -> Void {
        return { _, size, cg in
            let font = UIFont.systemFont(ofSize: size.width * sizeFraction, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(opacity)]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            cg.saveGState()
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: angleDegrees * .pi / 180)
            string.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attributes)
            cg.restoreGState()
        }
    }

    static func placements(_ items: [PagePlacement]) -> (Int, CGSize, CGContext) -> Void {
        return { index, size, _ in
            for item in items where item.pageIndex == index {
                switch item.content {
                case .image(let image):
                    let w = size.width * item.width
                    let h = image.size.width > 0 ? w * image.size.height / image.size.width : w
                    image.draw(in: CGRect(x: item.center.x * size.width - w / 2, y: item.center.y * size.height - h / 2, width: w, height: h))
                case .text(let text, let fontSize, let color):
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: color]
                    let string = text as NSString
                    let textSize = string.size(withAttributes: attributes)
                    string.draw(
                        at: CGPoint(x: item.center.x * size.width - textSize.width / 2, y: item.center.y * size.height - textSize.height / 2),
                        withAttributes: attributes
                    )
                }
            }
        }
    }
}

// MARK: - ID card sheet

enum IDCardComposer {
    /// Front (and optionally back) of a card on one page, at its real size, ready to print and copy.
    static func compose(front: CGImage, back: CGImage?, page: PageSizeOption = .a4, dpi: CGFloat = 200) -> CGImage? {
        let pagePoints = PDFBuilder.pageSize(for: CGSize(width: 1, height: 1.4), option: page == .auto ? .a4 : page)
        let pixels = CGSize(width: (pagePoints.width / 72 * dpi).rounded(), height: (pagePoints.height / 72 * dpi).rounded())
        let cardWidth = 85.6 / 25.4 * dpi
        let cardHeight = 53.98 / 25.4 * dpi
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixels))
            let gap = 0.5 / 25.4 * dpi * 30
            let count: CGFloat = back == nil ? 1 : 2
            let totalHeight = cardHeight * count + gap * (count - 1)
            var y = (pixels.height - totalHeight) / 3
            let x = (pixels.width - cardWidth) / 2
            for card in [front] + (back.map { [$0] } ?? []) {
                let rect = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
                let fit = PDFBuilder.aspectFit(CGSize(width: card.width, height: card.height), in: rect)
                UIImage(cgImage: card).draw(in: fit)
                UIColor(white: 0.75, alpha: 1).setStroke()
                let path = UIBezierPath(rect: fit)
                path.lineWidth = 2
                path.stroke()
                y += cardHeight + gap
            }
        }
        return image.cgImage
    }
}
