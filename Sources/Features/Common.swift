import SwiftUI
import UIKit
import PDFKit

// MARK: - Layout helpers

/// Header used at the top of every tool screen.
struct ToolHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).apDisplay(32)
            Text(subtitle).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A raised panel: the white or graphite card used for grouped content.
    func foliaCard(padding: CGFloat = AP.Space.m) -> some View {
        self
            .padding(padding)
            .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: AP.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(AP.Palette.brass)
                .accessibilityHidden(true)
            Text(title).apTitle(22).foregroundStyle(AP.Palette.paper).multilineTextAlignment(.center)
            Text(message).font(AP.Font.callout).foregroundStyle(AP.Palette.mist).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(AP.Space.l)
        .accessibilityElement(children: .combine)
    }
}

/// Small coloured note under a control: success, warning or error.
struct StatusLine: View {
    enum Tone { case success, failure, neutral }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Label(text, systemImage: symbol)
            .font(AP.Font.label)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .neutral: return "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: return AP.Palette.success
        case .failure: return AP.Palette.danger
        case .neutral: return AP.Palette.mist
        }
    }
}

// MARK: - Page pictures

/// A scanned page, drawn from its stored capture with the current crop, filter and rotation.
struct PageThumbnail: View {
    @EnvironmentObject private var store: DocStore
    let page: PageRecord
    /// Longest side in pixels.
    var pixels: Int = 480

    @State private var image: UIImage?
    /// True when the page could not be drawn (for example its stored picture is missing), so no endless spinner shows.
    @State private var failed = false

    var body: some View {
        ZStack {
            AP.Palette.sheet
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(AP.Palette.mist)
                    .accessibilityLabel(Text("Page picture unavailable"))
            } else {
                ProgressView()
            }
        }
        .task(id: "\(page.id.uuidString)-\(page.version)-\(pixels)") { await load() }
    }

    private func load() async {
        let storage = store.storage
        let snapshot = page
        let side = pixels
        let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
            storage.render(snapshot, maxSide: side, decodeSide: max(side, 900)).map { UIImage(cgImage: $0) }
        }.value
        if let rendered {
            image = rendered
            failed = false
        } else if image == nil {
            failed = true
        }
    }
}

/// A page of a PDF file.
struct PDFPageThumb: View {
    let document: PDFDocument
    let index: Int
    var width: CGFloat = 160

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            AP.Palette.sheet
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: "\(index)-\(width)") {
            guard let page = document.page(at: index) else { return }
            let size = PDFOps.pageSize(page)
            let scale = width * 2 / max(1, size.width)
            image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
        }
    }
}

// MARK: - Picture view with pinch zoom

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        if scroll.imageView?.image !== image {
            scroll.imageView?.image = image
            scroll.zoomScale = 1
            scroll.setNeedsLayout()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerContent()
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class ZoomScrollView: UIScrollView {
    var imageView: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.0001 {
            imageView?.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        centerContent()
    }

    func centerContent() {
        guard let imageView else { return }
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
    }
}

// MARK: - Export: share, save to Files, save to Photos, print

/// Every way out of Folia goes through here. Saving, sharing or printing asks the person to watch one short rewarded ad
/// (see `RewardedGate`); with no ad ready it is simply free.
struct FoliaExportBar: View {
    let files: [ExportFile]

    @State private var status: Status = .idle
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var exportURLs: [URL] = []
    @State private var showExporter = false

    private enum Status: Equatable {
        case idle, saving
        case saved(String)
        case failed(String)
        case cancelled
    }

    private static let cancelledText = "Export cancelled. Watch the short ad to export."

    /// Asks the rewarded gate first. "Not now" or closing the ad early shows a short note instead of exporting.
    private func gated(_ action: @escaping () -> Void) {
        if status == .cancelled { status = .idle }
        RewardedGate.shared.requestExport(action, onCancel: {
            withAnimation(.easeOut(duration: 0.2)) { status = .cancelled }
        })
    }

    private var allImages: Bool { !files.isEmpty && files.allSatisfy { $0.isImage } }
    private var canPrint: Bool { allImages || (files.count == 1 && files[0].kind == .pdf) }

    var body: some View {
        VStack(spacing: AP.Space.s) {
            Button {
                gated { share() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.apPrimaryWide)

            HStack(spacing: AP.Space.s) {
                Button {
                    gated { saveToFiles() }
                } label: {
                    Label("Files", systemImage: "folder")
                }
                .buttonStyle(.apSecondaryWide)

                if allImages {
                    Button {
                        gated { Task { await saveToPhotos() } }
                    } label: {
                        HStack(spacing: 6) {
                            if status == .saving { ProgressView() }
                            Label("Photos", systemImage: "photo")
                        }
                    }
                    .buttonStyle(.apSecondaryWide)
                    .disabled(status == .saving)
                }

                if canPrint {
                    Button {
                        gated { PrintHelper.print(files) }
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    .buttonStyle(.apSecondaryWide)
                }
            }

            switch status {
            case .saved(let text): StatusLine(text: text, tone: .success)
            case .failed(let text): StatusLine(text: text, tone: .failure)
            case .cancelled:
                StatusLine(text: Self.cancelledText, tone: .neutral)
                    .transition(.opacity)
            default: EmptyView()
            }
        }
        .disabled(files.isEmpty)
        .task(id: status) {
            // The cancelled note is a hint, not a state: it fades away after a few seconds.
            guard status == .cancelled else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, status == .cancelled {
                withAnimation(.easeOut(duration: 0.3)) { status = .idle }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(urls: shareURLs)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showExporter) {
            ExportPicker(urls: exportURLs) { saved in
                if saved { status = .saved("Saved to Files") }
            }
            .ignoresSafeArea()
        }
    }

    private func urls() -> [URL]? {
        let result = files.compactMap { $0.temporaryURL() }
        guard result.count == files.count, !result.isEmpty else {
            status = .failed("Could not prepare the file. Try again.")
            return nil
        }
        return result
    }

    private func share() {
        guard let urls = urls() else { return }
        shareURLs = urls
        showShare = true
    }

    private func saveToFiles() {
        guard let urls = urls() else { return }
        exportURLs = urls
        showExporter = true
    }

    private func saveToPhotos() async {
        status = .saving
        let items = files.map { ExportItem(data: $0.data, filename: $0.filename, format: $0.kind == .png ? .png : .jpeg) }
        do {
            try await LibrarySaver.save(items)
            APHaptics.success()
            status = .saved(items.count == 1 ? "Saved to Photos" : "Saved \(items.count) pictures to Photos")
        } catch LibrarySaver.SaveError.denied {
            status = .failed("Allow Photos access in Settings to save. You can still share.")
        } catch {
            status = .failed("Could not save. Try again, or share the file instead.")
        }
    }
}

struct ExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish(false) }
    }
}

enum PrintHelper {
    @MainActor
    static func print(_ files: [ExportFile]) {
        guard !files.isEmpty else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = files[0].filename
        if files[0].kind == .pdf {
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = files[0].data
        } else {
            info.outputType = .photo
            controller.printInfo = info
            controller.printingItems = files.compactMap { UIImage(data: $0.data) }
        }
        controller.present(animated: true, completionHandler: nil)
    }
}

// MARK: - Short text helpers

enum FoliaText {
    static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
