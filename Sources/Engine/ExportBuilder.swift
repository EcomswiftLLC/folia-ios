import UIKit
import UniformTypeIdentifiers

// MARK: - Options

enum ExportQuality: String, CaseIterable, Identifiable {
    case small, standard, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .small: return "Smallest file, fine for email"
        case .standard: return "Sharp text, moderate size"
        case .high: return "Best for printing"
        }
    }

    /// Longest side of each page picture, in pixels.
    var maxSide: Int {
        switch self {
        case .small: return 1400
        case .standard: return 2000
        case .high: return 2800
        }
    }

    var jpegQuality: Double {
        switch self {
        case .small: return 0.6
        case .standard: return 0.78
        case .high: return 0.9
        }
    }
}

struct ExportOptions: Equatable {
    var pageSize: PageSizeOption = FoliaPrefs.pageSize
    var quality: ExportQuality = FoliaPrefs.quality
    var searchable: Bool = true
}

// MARK: - A finished file

struct ExportFile: Identifiable {
    enum Kind { case pdf, jpeg, png, text }

    let id = UUID()
    let data: Data
    let filename: String
    let kind: Kind
    /// PDF only: pages of the document that could not be drawn and are missing from this file.
    var skippedPages: Int = 0

    var utType: UTType {
        switch kind {
        case .pdf: return .pdf
        case .jpeg: return .jpeg
        case .png: return .png
        case .text: return .plainText
        }
    }

    var isImage: Bool { kind == .jpeg || kind == .png }

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FoliaExports", isDirectory: true)
    }

    /// Writes the file to a temporary folder so it can be shared, saved to Files or printed. Every call uses a folder
    /// of its own, so removing one copy never affects another that is still in use.
    func temporaryURL() -> URL? {
        let directory = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Called at launch: removes copies left behind by an earlier session.
    static func cleanTemporary() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes copies made by `temporaryURL()` once sharing or saving is finished. Anything outside the export
    /// folder is left alone.
    static func removeTemporary(_ urls: [URL]) {
        let root = folder.standardizedFileURL.path
        for url in urls {
            let directory = url.deletingLastPathComponent().standardizedFileURL
            if directory.deletingLastPathComponent().path == root {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// A title that is safe to use as a file name.
    static func safeName(_ title: String, fallback: String = "Scan") -> String {
        let blocked = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = title.components(separatedBy: blocked).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if collapsed.isEmpty { return fallback }
        return String(collapsed.prefix(80))
    }
}

// MARK: - Building

enum ExportBuilder {
    /// The whole document as one PDF. Pages are rendered one at a time. Pages that cannot be drawn are left out and
    /// counted in `skippedPages`. Returns nil when no page at all could be drawn.
    static func pdf(doc: DocRecord, storage: PageStorage, options: ExportOptions) -> ExportFile? {
        let built = PDFBuilder.makePDFReporting(
            count: doc.pages.count,
            pageSize: options.pageSize,
            quality: options.quality.jpegQuality,
            title: doc.title
        ) { index in
            // A cancelled build (the person changed an option) stops drawing; its result is thrown away.
            if Task.isCancelled { return nil }
            let page = doc.pages[index]
            guard let image = storage.render(page, maxSide: options.quality.maxSide) else { return nil }
            return PDFPageInput(image: image, ocr: options.searchable ? page.ocr : nil)
        }
        guard doc.pages.count - built.skipped > 0 else { return nil }
        var file = ExportFile(data: built.data, filename: ExportFile.safeName(doc.title) + ".pdf", kind: .pdf)
        file.skippedPages = built.skipped
        return file
    }

    /// Every page as a picture.
    static func images(doc: DocRecord, storage: PageStorage, options: ExportOptions, format: OutputFormat) -> [ExportFile] {
        var files: [ExportFile] = []
        let base = ExportFile.safeName(doc.title)
        for (index, page) in doc.pages.enumerated() {
            if Task.isCancelled { break }
            autoreleasepool {
                guard let image = storage.render(page, maxSide: options.quality.maxSide),
                      let data = ImageCodec.encode(image, format: format, quality: options.quality.jpegQuality) else { return }
                let suffix = doc.pages.count > 1 ? "-\(index + 1)" : ""
                files.append(ExportFile(
                    data: data,
                    filename: "\(base)\(suffix).\(format.fileExtension)",
                    kind: format == .png ? .png : .jpeg
                ))
            }
        }
        return files
    }

    /// Recognised text of the whole document, with a blank line between pages.
    static func text(doc: DocRecord) -> ExportFile? {
        let pages = doc.pages.compactMap { $0.ocr }.map { OCREngine.plainText($0) }.filter { !$0.isEmpty }
        guard !pages.isEmpty, let data = pages.joined(separator: "\n\n").data(using: .utf8) else { return nil }
        return ExportFile(data: data, filename: ExportFile.safeName(doc.title) + ".txt", kind: .text)
    }
}
