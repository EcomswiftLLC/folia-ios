import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Filters

/// Looks a scanned page can have. Every one starts from the untouched capture, so switching is never destructive.
enum ScanFilter: String, Codable, CaseIterable, Identifiable {
    case original, auto, magic, gray, bw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .auto: return "Auto"
        case .magic: return "Magic colour"
        case .gray: return "Grayscale"
        case .bw: return "Black & white"
        }
    }

    /// Short name for the small look tiles in the page editor, so it never truncates.
    var shortTitle: String {
        switch self {
        case .bw: return "B&W"
        default: return title
        }
    }

    /// Spoken name for VoiceOver.
    var accessibilityTitle: String {
        switch self {
        case .bw: return "Black and white"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .original: return "photo"
        case .auto: return "wand.and.stars"
        case .magic: return "sparkles"
        case .gray: return "circle.lefthalf.filled"
        case .bw: return "doc.text"
        }
    }
}

/// Four corners of a page inside a photo, normalised 0...1 with the origin at the top left.
struct Quad: Codable, Equatable {
    var tl: CGPoint
    var tr: CGPoint
    var br: CGPoint
    var bl: CGPoint

    static let full = Quad(tl: CGPoint(x: 0, y: 0), tr: CGPoint(x: 1, y: 0), br: CGPoint(x: 1, y: 1), bl: CGPoint(x: 0, y: 1))

    var isFull: Bool {
        let e: CGFloat = 0.004
        return abs(tl.x) < e && abs(tl.y) < e && abs(tr.x - 1) < e && abs(tr.y) < e
            && abs(br.x - 1) < e && abs(br.y - 1) < e && abs(bl.x) < e && abs(bl.y - 1) < e
    }

    var points: [CGPoint] { [tl, tr, br, bl] }

    /// A quad that is convex, large enough and inside the photo.
    var isUsable: Bool {
        let pts = points
        for p in pts where p.x < -0.01 || p.x > 1.01 || p.y < -0.01 || p.y > 1.01 { return false }
        var area: CGFloat = 0
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) > 1e-6 {
                if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
            }
            area += pts[i].x * b.y - b.x * pts[i].y
        }
        return abs(area) / 2 > 0.04
    }
}

// MARK: - Rendering

enum PageRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Filters are tuned for a readable page. On a tiny picture the text is averaged into grey before the filter
    /// runs, and the clean-up then whitens it away, so small renders are filtered at this size and scaled down after.
    static let minimumFilterSide = 900

    /// Turns a capture into the page the person sees: straighten (perspective), filter, rotate.
    static func render(_ source: CGImage, filter: ScanFilter, quad: Quad?, quarterTurns: Int, maxSide: Int? = nil) -> CGImage? {
        var image = CIImage(cgImage: source)
        if let quad, !quad.isFull, quad.isUsable {
            image = perspective(image, quad: quad)
        }
        if let maxSide {
            let workSide = filter == .original ? maxSide : max(maxSide, minimumFilterSide)
            image = downscaled(image, to: workSide)
        }
        image = apply(filter, to: image)
        if let maxSide {
            image = downscaled(image, to: maxSide)
            // Thin text turns light grey when a filtered page is shrunk to a thumbnail, so darken the mid tones a little.
            if filter != .original, maxSide <= 700 {
                image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.4])
            }
        }
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        return cgImage(image)
    }

    /// Scales the picture down so its longest side is at most `side` pixels, keeping its origin at zero.
    private static func downscaled(_ image: CIImage, to side: Int) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest.isFinite, longest > CGFloat(side), side > 0 else { return image }
        let scale = CGFloat(side) / longest
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        let raw = image.extent
        guard raw.width.isFinite, raw.height.isFinite else { return nil }
        let rect = CGRect(x: raw.minX.rounded(), y: raw.minY.rounded(), width: raw.width.rounded(), height: raw.height.rounded())
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: srgb)
    }

    static func perspective(_ image: CIImage, quad: Quad) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * w + image.extent.minX, y: (1 - q.y) * h + image.extent.minY) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = p(quad.tl)
        filter.topRight = p(quad.tr)
        filter.bottomRight = p(quad.br)
        filter.bottomLeft = p(quad.bl)
        guard let out = filter.outputImage else { return image }
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    // MARK: Filters

    static func apply(_ filter: ScanFilter, to input: CIImage) -> CIImage {
        switch filter {
        case .original:
            return input
        case .auto:
            var image = input
            if let enhancer = CIFilter(name: "CIDocumentEnhancer") {
                enhancer.setValue(input, forKey: kCIInputImageKey)
                enhancer.setValue(5.0, forKey: "inputAmount")
                if let out = enhancer.outputImage { image = out }
            } else {
                image = flatten(input)
            }
            return sharpen(colorControls(image, saturation: 1.05, contrast: 1.1, brightness: 0.01))
        case .magic:
            return sharpen(colorControls(flatten(input), saturation: 1.2, contrast: 1.25, brightness: 0))
        case .gray:
            return sharpen(colorControls(flatten(input), saturation: 0, contrast: 1.2, brightness: 0.01))
        case .bw:
            let gray = colorControls(flatten(input), saturation: 0, contrast: 1.1, brightness: 0)
            let curve = CIFilter.toneCurve()
            curve.inputImage = gray
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.35, y: 0.0)
            curve.point2 = CGPoint(x: 0.55, y: 0.3)
            curve.point3 = CGPoint(x: 0.72, y: 0.95)
            curve.point4 = CGPoint(x: 1, y: 1)
            return curve.outputImage ?? gray
        }
    }

    private static func colorControls(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return f.outputImage ?? image
    }

    private static func sharpen(_ image: CIImage) -> CIImage {
        let f = CIFilter.sharpenLuminance()
        f.inputImage = image
        f.sharpness = 0.35
        return f.outputImage ?? image
    }

    /// Evens out shadows and uneven light: the blurred page is inverted and added back, so the paper becomes white.
    private static func flatten(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let sigma = max(extent.width, extent.height) * 0.02
        let blur = image.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
        let inverted = blur.applyingFilter("CIColorInvert")
        let out = image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: inverted])
        return out.cropped(to: extent)
    }
}

// MARK: - Finding the page in a photo

enum DocumentDetector {
    /// The page edges in a photo, or nil when none were found (for example on a plain scan that fills the frame).
    static func detect(_ image: CGImage) -> Quad? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let segmentation = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([segmentation])) != nil,
           let observation = segmentation.results?.first, observation.confidence > 0.4 {
            let found = quad(from: observation)
            if found.isUsable { return found }
        }
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumAspectRatio = 1.0
        rectangles.minimumSize = 0.3
        rectangles.minimumConfidence = 0.6
        rectangles.quadratureTolerance = 25
        rectangles.maximumObservations = 1
        if (try? handler.perform([rectangles])) != nil, let observation = rectangles.results?.first {
            let found = quad(from: observation)
            if found.isUsable { return found }
        }
        return nil
    }

    private static func quad(from o: VNRectangleObservation) -> Quad {
        Quad(
            tl: CGPoint(x: o.topLeft.x, y: 1 - o.topLeft.y),
            tr: CGPoint(x: o.topRight.x, y: 1 - o.topRight.y),
            br: CGPoint(x: o.bottomRight.x, y: 1 - o.bottomRight.y),
            bl: CGPoint(x: o.bottomLeft.x, y: 1 - o.bottomLeft.y)
        )
    }
}

// MARK: - Text recognition

/// One recognised line of text. The box is normalised 0...1 with the origin at the BOTTOM left (Vision convention).
struct OCRLine: Codable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

enum OCREngine {
    /// Reads text on the device with Apple's Vision framework. Nothing is uploaded.
    static func recognize(_ image: CGImage, accurate: Bool = true) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        var lines: [OCRLine] = []
        for observation in results {
            guard let top = observation.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let box = observation.boundingBox
            lines.append(OCRLine(text: text, x: box.minX, y: box.minY, w: box.width, h: box.height))
        }
        // Reading order: top to bottom, then left to right.
        return lines.sorted { a, b in
            if abs(a.y - b.y) > 0.012 { return a.y > b.y }
            return a.x < b.x
        }
    }

    static func plainText(_ lines: [OCRLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}
