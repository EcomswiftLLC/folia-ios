import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Photos
import PhotosUI

// MARK: - Formats

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }

    /// PNG is lossless, so a quality value does nothing for it.
    var usesQuality: Bool { self != .png }

    /// HEIC encoding is available on every supported device, but the check keeps the picker honest.
    static var available: [OutputFormat] {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { supported.contains($0.utType.identifier) }
    }
}

// MARK: - A photo that has been read from the library

struct LoadedPhoto: Identifiable {
    let id = UUID()
    /// Decoded pixels when the photo was loaded eagerly (single-photo screens). Batch tools leave this empty and decode on demand,
    /// so twenty photos never sit in memory as twenty large bitmaps at once.
    private let storedImage: CGImage?
    /// The bytes the person picked, untouched.
    let originalData: Data
    /// Metadata dictionary of the original file (EXIF, GPS, TIFF ...).
    let properties: [String: Any]
    let name: String
    /// Upright pixel size of `image` (EXIF orientation applied, capped to the size the caller asked for).
    let pixelSize: CGSize
    private let maxPixel: Int

    init(image: CGImage, originalData: Data, properties: [String: Any], name: String) {
        storedImage = image
        self.originalData = originalData
        self.properties = properties
        self.name = name
        pixelSize = CGSize(width: image.width, height: image.height)
        maxPixel = max(image.width, image.height)
    }

    init(lazyData: Data, properties: [String: Any], name: String, pixelSize: CGSize, maxPixel: Int) {
        storedImage = nil
        originalData = lazyData
        self.properties = properties
        self.name = name
        self.pixelSize = pixelSize
        self.maxPixel = maxPixel
    }

    /// Upright pixels (EXIF orientation already applied). For lazily loaded photos this decodes the file each time it is read,
    /// so read it once per job and let it go.
    var image: CGImage {
        if let storedImage { return storedImage }
        return PhotoLoader.decode(originalData, maxPixel: maxPixel) ?? PhotoLoader.blank
    }

    var originalBytes: Int { originalData.count }
    var uiImage: UIImage { UIImage(cgImage: image) }
}

enum PhotoLoader {
    /// A single transparent pixel, only used if a file that decoded once can no longer be read.
    static let blank: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    /// Reads a picked item. Returns nil if the data cannot be decoded as an image.
    static func load(_ item: PhotosPickerItem, maxPixel: Int = 4096, name: String? = nil, lazy: Bool = false) async -> LoadedPhoto? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        if lazy { return loadLazy(data: data, maxPixel: maxPixel, name: name ?? "Photo") }
        return load(data: data, maxPixel: maxPixel, name: name ?? "Photo")
    }

    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func load(data: Data, maxPixel: Int = 4096, name: String = "Photo") -> LoadedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = decode(data, maxPixel: maxPixel) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        return LoadedPhoto(image: image, originalData: data, properties: props, name: name)
    }

    /// Reads only the header: the pixels are decoded later, one photo at a time, when a tool processes it.
    static func loadLazy(data: Data, maxPixel: Int = 4096, name: String = "Photo") -> LoadedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        var size = orientation >= 5 && orientation <= 8 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let longest = max(size.width, size.height)
        if longest > Double(maxPixel) {
            let ratio = Double(maxPixel) / longest
            size = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        }
        return LoadedPhoto(lazyData: data, properties: props, name: name, pixelSize: size, maxPixel: maxPixel)
    }
}

/// Holds the photos a tool is working on and loads picker items in the background.
@MainActor
final class PhotoSelection: ObservableObject {
    @Published var photos: [LoadedPhoto] = []
    @Published var isLoading = false
    @Published var failedCount = 0

    func load(_ items: [PhotosPickerItem], maxPixel: Int = 4096, append: Bool = false, lazy: Bool = true) async {
        guard !items.isEmpty else { return }
        isLoading = true
        failedCount = 0
        var result: [LoadedPhoto] = append ? photos : []
        for (index, item) in items.enumerated() {
            if let photo = await PhotoLoader.load(item, maxPixel: maxPixel, name: "Photo \(result.count + 1)", lazy: lazy) {
                result.append(photo)
            } else {
                failedCount += 1
            }
            _ = index
        }
        photos = result
        isLoading = false
    }

    func remove(_ id: UUID) { photos.removeAll { $0.id == id } }
    func clear() { photos = []; failedCount = 0 }
}

// MARK: - Encoding and resizing

enum ImageCodec {
    /// Encodes pixels as a file. `properties` are copied into the file (without orientation, because pixels are already upright).
    static func encode(
        _ image: CGImage,
        format: OutputFormat,
        quality: Double = 0.9,
        properties: [String: Any]? = nil
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        // JPEG has no transparency, so transparent pixels would turn black. Put them on white instead.
        let image = format == .jpeg ? flattenedOnWhite(image) : image
        var options: [CFString: Any] = [:]
        if let properties {
            for (key, value) in sanitized(properties) { options[key as CFString] = value }
        }
        if format.usesQuality {
            options[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.01, quality))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Draws a picture with transparency onto an opaque white background. Opaque pictures are returned unchanged.
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let own = image.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Removes keys that no longer describe the exported pixels.
    static func sanitized(_ properties: [String: Any]) -> [String: Any] {
        var result = properties
        for key in [
            kCGImagePropertyOrientation as String,
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImagePropertyDepth as String,
            kCGImagePropertyHasAlpha as String,
            kCGImagePropertyColorModel as String,
            kCGImagePropertyProfileName as String,
        ] {
            result.removeValue(forKey: key)
        }
        for dictionaryKey in [kCGImagePropertyTIFFDictionary as String, kCGImagePropertyExifDictionary as String] {
            if var inner = result[dictionaryKey] as? [String: Any] {
                inner.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
                inner.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                inner.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                result[dictionaryKey] = inner
            }
        }
        return result
    }

    /// Metadata with everything that identifies a person or place removed (GPS, device serial, owner names).
    static func privacySafe(_ properties: [String: Any]) -> [String: Any] {
        var result = sanitized(properties)
        result.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
        result.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
        result.removeValue(forKey: kCGImagePropertyIPTCDictionary as String)
        if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            for key in [
                kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
                kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment,
            ] { exif.removeValue(forKey: key as String) }
            result[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFArtist as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFHostComputer as String)
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return result
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if width == image.width && height == image.height { return image }
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let own = image.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        let info = hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
            )
        guard let ctx = context else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Scales so the longer side is at most `maxPixel`. Never enlarges.
    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, maxPixel > 0 else { return image }
        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        return scaled(image, to: CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio))
    }

    /// Finds the best JPEG or HEIC quality whose file is at most `targetBytes`. If even the lowest quality is too large,
    /// the image is scaled down in steps until it fits. Returns the data and the pixel size that was used.
    static func encode(
        _ image: CGImage,
        format: OutputFormat,
        targetBytes: Int,
        properties: [String: Any]? = nil
    ) -> (data: Data, size: CGSize)? {
        guard format.usesQuality else {
            return encode(image, format: format, properties: properties).map { ($0, CGSize(width: image.width, height: image.height)) }
        }
        var current = image
        for _ in 0..<8 {
            var low = 0.05, high = 0.95
            var best: Data?
            for _ in 0..<7 {
                let mid = (low + high) / 2
                guard let data = encode(current, format: format, quality: mid, properties: properties) else { return nil }
                if data.count <= targetBytes { best = data; low = mid } else { high = mid }
            }
            if let best { return (best, CGSize(width: current.width, height: current.height)) }
            guard let smaller = scaled(
                current,
                to: CGSize(width: CGFloat(current.width) * 0.8, height: CGFloat(current.height) * 0.8)
            ), smaller.width > 64 else { break }
            current = smaller
        }
        guard let data = encode(current, format: format, quality: 0.05, properties: properties) else { return nil }
        return (data, CGSize(width: current.width, height: current.height))
    }
}

// MARK: - Sizes for display

enum ByteText {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Output files

struct ExportItem: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let format: OutputFormat

    var contentType: UTType { format.utType }

    /// Writes the file to the temporary folder so it can be shared.
    func temporaryURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func uniqueName(_ base: String, format: OutputFormat) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 100_000_000
        return "\(base)-\(stamp).\(format.fileExtension)"
    }
}

enum LibrarySaver {
    enum SaveError: Error { case denied, failed }

    /// Adds the files to the photo library. Needs the "add only" permission, which the system asks for once.
    static func save(_ items: [ExportItem]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = item.format.utType.identifier
                request.addResource(with: .photo, data: item.data, options: options)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
