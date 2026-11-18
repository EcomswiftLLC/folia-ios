import SwiftUI
import UIKit
import VisionKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Camera

/// Apple's document camera: finds the page, takes the shot by itself and lets the person scan several pages in a row.
struct CameraScanner: UIViewControllerRepresentable {
    /// Hands over the finished scan itself, so its pages can be prepared one at a time off the main thread.
    var onFinish: (VNDocumentCameraScan) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: CameraScanner
        init(_ parent: CameraScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onCancel() }
    }
}

// MARK: - Controller

/// One place that starts every way of adding pages: camera, Photos and Files.
@MainActor
final class ImportController: ObservableObject {
    @Published var showCamera = false
    @Published var showPhotos = false
    @Published var showFiles = false
    @Published var photoItems: [PhotosPickerItem] = []
    @Published var isWorking = false
    @Published var message: String?
    /// A document that was just created. The library opens it.
    @Published var openDoc: UUID?

    /// When set, new pages go into this document instead of a new one.
    private(set) var appendTo: UUID?
    /// Pages of the current import that could not be read or stored. Reported once, in `complete`.
    private var failedPages = 0

    /// Stores prepared pages and remembers how many could not be written.
    private func addSources(_ sources: [ScanImporter.Source], title: String? = nil, store: DocStore) -> UUID? {
        let result = store.importSourcesReporting(sources, into: appendTo, title: title)
        failedPages += result.failed
        return result.docID
    }

    static func failureText(_ count: Int) -> String {
        let what = count == 1 ? "1 page" : "\(count) pages"
        return "\(what) could not be added. The picture may be damaged, or this device may be low on storage."
    }

    func scan(into doc: UUID? = nil) {
        appendTo = doc
        if VNDocumentCameraViewController.isSupported {
            showCamera = true
        } else {
            message = "Scanning needs a camera, and this device has none available. Add pages from Photos or Files instead."
        }
    }

    func choosePhotos(into doc: UUID? = nil) {
        appendTo = doc
        showPhotos = true
    }

    func chooseFiles(into doc: UUID? = nil) {
        appendTo = doc
        showFiles = true
    }

    /// Each page is turned upright, scaled and JPEG encoded on its own, off the main thread, so a long scan never holds
    /// every full-size picture in memory at once.
    func finishScan(_ scan: VNDocumentCameraScan, store: DocStore) async {
        isWorking = true
        defer { isWorking = false }
        guard scan.pageCount > 0 else { return }
        failedPages = 0
        let pageCount = scan.pageCount
        let sources: [ScanImporter.Source] = await Task.detached(priority: .userInitiated) {
            var result: [ScanImporter.Source] = []
            for index in 0..<scan.pageCount {
                autoreleasepool {
                    if let image = ScanImporter.upright(scan.imageOfPage(at: index)),
                       let source = ScanImporter.makeSource(image, detect: false) {
                        result.append(source)
                    }
                }
            }
            return result
        }.value
        failedPages += max(0, pageCount - sources.count)
        let id = addSources(sources, store: store)
        complete(id)
    }

    func finishPhotos(store: DocStore) async {
        let items = photoItems
        photoItems = []
        guard !items.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        failedPages = 0
        var sources: [ScanImporter.Source] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let source = await Task.detached(priority: .userInitiated) { ScanImporter.makeSource(data: data, detect: true) }.value
            if let source { sources.append(source) }
        }
        failedPages += items.count - sources.count
        guard !sources.isEmpty else {
            failedPages = 0
            message = "Those photos could not be opened."
            return
        }
        let id = addSources(sources, store: store)
        complete(id)
    }

    func finishFiles(_ urls: [URL], store: DocStore) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        failedPages = 0
        var lastID: UUID?
        var pictures: [ScanImporter.Source] = []
        var skippedLocked = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url) else { continue }
                if document.isLocked { skippedLocked += 1; continue }
                // Pages are drawn and written to disk in small batches, so a long PDF stays within memory.
                let title = url.deletingPathExtension().lastPathComponent
                let result = await store.importPDF(document, title: appendTo == nil ? title : nil, into: appendTo)
                failedPages += result.failed
                if let id = result.docID { lastID = id }
            } else if let data = try? Data(contentsOf: url) {
                let source = await Task.detached(priority: .userInitiated) { ScanImporter.makeSource(data: data, detect: true) }.value
                if let source { pictures.append(source) } else { failedPages += 1 }
            }
        }
        if !pictures.isEmpty {
            if let id = addSources(pictures, store: store) { lastID = id }
        }
        if lastID == nil {
            failedPages = 0
            message = skippedLocked > 0
                ? "That PDF is password protected. Remove the password in Tools first, then add it."
                : "Those files could not be opened."
            return
        }
        if skippedLocked > 0 { message = "A password protected PDF was skipped. Remove its password in Tools first." }
        complete(lastID)
    }

    private func complete(_ id: UUID?) {
        let failed = failedPages
        failedPages = 0
        guard let id else {
            message = "Nothing could be added. Try again."
            return
        }
        if appendTo == nil { openDoc = id }
        appendTo = nil
        if failed > 0 {
            let text = Self.failureText(failed)
            message = message.map { $0 + " " + text } ?? text
        }
    }
}

// MARK: - Presentation

private struct ImportSheets: ViewModifier {
    @ObservedObject var importer: ImportController
    @EnvironmentObject private var store: DocStore

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $importer.showCamera) {
                CameraScanner(
                    onFinish: { scan in
                        importer.showCamera = false
                        // Show progress straight away, before any page is prepared.
                        importer.isWorking = true
                        Task { await importer.finishScan(scan, store: store) }
                    },
                    onCancel: { importer.showCamera = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $importer.showPhotos, selection: $importer.photoItems, maxSelectionCount: 40, matching: .images)
            .onChange(of: importer.photoItems) { _, items in
                if !items.isEmpty { Task { await importer.finishPhotos(store: store) } }
            }
            .fileImporter(isPresented: $importer.showFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await importer.finishFiles(urls, store: store) } }
            }
            .overlay {
                if importer.isWorking {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: AP.Space.m) {
                            ProgressView().controlSize(.large)
                            Text("Adding pages").font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                        }
                        .padding(AP.Space.l)
                        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
            .alert(
                "Folia",
                isPresented: Binding(get: { importer.message != nil }, set: { if !$0 { importer.message = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importer.message ?? "")
            }
    }
}

extension View {
    func importSheets(_ importer: ImportController) -> some View {
        modifier(ImportSheets(importer: importer))
    }
}

// MARK: - Add pages menu

/// The three ways to add pages, used by the library and by an open document.
struct AddPagesMenu<Label: View>: View {
    @EnvironmentObject private var importer: ImportController
    var into: UUID?
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button { importer.scan(into: into) } label: { SwiftUI.Label("Scan with camera", systemImage: "camera.viewfinder") }
            Button { importer.choosePhotos(into: into) } label: { SwiftUI.Label("Choose from Photos", systemImage: "photo.on.rectangle") }
            Button { importer.chooseFiles(into: into) } label: { SwiftUI.Label("Import from Files", systemImage: "folder") }
        } label: {
            label()
        }
    }
}
