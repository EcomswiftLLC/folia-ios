import SwiftUI
import UIKit
import VisionKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Camera

/// Apple's document camera: finds the page, takes the shot by itself and lets the person scan several pages in a row.
struct CameraScanner: UIViewControllerRepresentable {
    var onFinish: ([CGImage]) -> Void
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
            var images: [CGImage] = []
            for index in 0..<scan.pageCount {
                if let image = ScanImporter.upright(scan.imageOfPage(at: index)) { images.append(image) }
            }
            parent.onFinish(images)
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

    func finishScan(_ images: [CGImage], store: DocStore) async {
        guard !images.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let id = await store.importImages(images, detect: false, into: appendTo)
        complete(id)
    }

    func finishPhotos(store: DocStore) async {
        let items = photoItems
        photoItems = []
        guard !items.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var images: [CGImage] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let decoded = await Task.detached(priority: .userInitiated) { PhotoLoader.decode(data, maxPixel: 3000) }.value
            if let decoded { images.append(decoded) }
        }
        guard !images.isEmpty else {
            message = "Those photos could not be opened."
            return
        }
        let id = await store.importImages(images, detect: true, into: appendTo)
        complete(id)
    }

    func finishFiles(_ urls: [URL], store: DocStore) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var lastID: UUID?
        var pictures: [CGImage] = []
        var skippedLocked = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url) else { continue }
                if document.isLocked { skippedLocked += 1; continue }
                let pages = await Task.detached(priority: .userInitiated) { PDFOps.images(document, maxSide: 2400) }.value
                guard !pages.isEmpty else { continue }
                let title = url.deletingPathExtension().lastPathComponent
                if let appendTo {
                    lastID = await store.importImages(pages, detect: false, into: appendTo)
                } else {
                    lastID = await store.importImages(pages, detect: false, title: title)
                }
            } else if let data = try? Data(contentsOf: url) {
                let decoded = await Task.detached(priority: .userInitiated) { PhotoLoader.decode(data, maxPixel: 3000) }.value
                if let decoded { pictures.append(decoded) }
            }
        }
        if !pictures.isEmpty {
            lastID = await store.importImages(pictures, detect: true, into: appendTo)
        }
        if lastID == nil {
            message = skippedLocked > 0
                ? "That PDF is password protected. Remove the password in Tools first, then add it."
                : "Those files could not be opened."
            return
        }
        if skippedLocked > 0 { message = "A password protected PDF was skipped. Remove its password in Tools first." }
        complete(lastID)
    }

    private func complete(_ id: UUID?) {
        guard let id else {
            message = "Nothing could be added. Try again."
            return
        }
        if appendTo == nil { openDoc = id }
        appendTo = nil
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
                    onFinish: { images in
                        importer.showCamera = false
                        Task { await importer.finishScan(images, store: store) }
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
