import SwiftUI

struct ExportSheet: View {
    let docID: UUID

    @EnvironmentObject private var store: DocStore
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case pdf, jpg
        var id: String { rawValue }
        var title: String { self == .pdf ? "PDF" : "JPG pictures" }
    }

    @State private var format: Format = .pdf
    @State private var options = ExportOptions()
    @State private var files: [ExportFile] = []
    @State private var preparing = true
    /// Keeps track of the build in progress, so a newer one waits for it and only the latest result is used.
    @State private var gate = ExportBuildGate()

    private var doc: DocRecord? { store.doc(docID) }

    /// Pages of the document that are missing from the prepared file because their picture could not be read.
    private var skippedPages: Int {
        switch format {
        case .pdf: return files.first?.skippedPages ?? 0
        case .jpg: return max(0, (doc?.pages.count ?? 0) - files.count)
        }
    }

    /// Changes whenever the output would change.
    private var key: String {
        let versions = (doc?.pages ?? []).map { "\($0.id.uuidString.prefix(4))\($0.version)" }.joined()
        return "\(format.rawValue)-\(options.pageSize.rawValue)-\(options.quality.rawValue)-\(options.searchable)-\(versions)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Export", subtitle: doc.map { "\($0.title), \(FoliaText.pages($0.pages.count))" } ?? "")

                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: AP.Space.m) {
                        if format == .pdf {
                            VStack(alignment: .leading, spacing: AP.Space.s) {
                                Text("Page size").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                                WrapChips {
                                    ForEach(PageSizeOption.allCases) { size in
                                        APChip(title: size.title, selected: options.pageSize == size) { options.pageSize = size }
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: AP.Space.s) {
                            Text("Quality").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                            WrapChips {
                                ForEach(ExportQuality.allCases) { quality in
                                    APChip(title: quality.title, selected: options.quality == quality) { options.quality = quality }
                                }
                            }
                            Text(options.quality.detail).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if format == .pdf {
                            Toggle(isOn: $options.searchable) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Searchable text").font(AP.Font.body).foregroundStyle(AP.Palette.paper)
                                    Text("Search and copy words inside the PDF. The first export takes a little longer.")
                                        .font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                                }
                            }
                            .tint(AP.Palette.brass)
                        }
                    }
                    .foliaCard()

                    summary

                    FoliaExportBar(files: preparing ? [] : files)
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.xl)
                .readableWidth()
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task(id: key) { await prepare() }
            .onChange(of: options) { _, new in
                FoliaPrefs.pageSize = new.pageSize
                FoliaPrefs.quality = new.quality
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if preparing {
            HStack(spacing: AP.Space.s) {
                ProgressView()
                Text(format == .pdf && options.searchable ? "Reading text and building the PDF" : "Preparing your file")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
            }
        } else if files.isEmpty {
            StatusLine(text: "Could not prepare this document. Close and try again.", tone: .failure)
        } else {
            let total = files.reduce(0) { $0 + $1.data.count }
            let name = files.count == 1 ? files[0].filename : "\(files.count) pictures"
            let skipped = skippedPages
            VStack(alignment: .leading, spacing: AP.Space.s) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(AP.Font.headline).foregroundStyle(AP.Palette.paper).lineLimit(2)
                        Text(ByteText.string(total)).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                    }
                    Spacer()
                    Image(systemName: skipped > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(skipped > 0 ? AP.Palette.danger : AP.Palette.success)
                }
                .accessibilityElement(children: .combine)
                if skipped > 0 {
                    StatusLine(
                        text: skipped == 1
                            ? "1 page could not be read and is missing from this file."
                            : "\(skipped) pages could not be read and are missing from this file.",
                        tone: .failure
                    )
                }
            }
        }
    }

    private func prepare() async {
        preparing = true
        guard var current = doc else {
            // The document is gone (deleted elsewhere): stop the spinner and show the failure line.
            files = []
            preparing = false
            return
        }
        if format == .pdf && options.searchable {
            await store.recognizeText(docID: docID)
            current = store.doc(docID) ?? current
        }
        if Task.isCancelled { return }
        let storage = store.storage
        let settings = options
        let snapshot = current
        let wanted = format
        // Only one full-document build runs at a time. A newer request cancels the one in progress and starts after
        // it has stopped; a cancelled build returns nothing and its result is never shown.
        let previous = gate.current
        previous?.cancel()
        let work = Task.detached(priority: .userInitiated) { () -> [ExportFile] in
            _ = await previous?.value
            if Task.isCancelled { return [] }
            switch wanted {
            case .pdf: return ExportBuilder.pdf(doc: snapshot, storage: storage, options: settings).map { [$0] } ?? []
            case .jpg: return ExportBuilder.images(doc: snapshot, storage: storage, options: settings, format: .jpeg)
            }
        }
        gate.current = work
        let built = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled { return }
        files = built
        preparing = false
    }
}

/// Holds the export build that is currently running (see `ExportSheet.prepare`).
final class ExportBuildGate {
    var current: Task<[ExportFile], Never>?
}

// MARK: - Recognised text

struct TextResultView: View {
    let docID: UUID

    @EnvironmentObject private var store: DocStore
    @State private var working = true
    @State private var copied = false
    /// A short note under the copy button: the ad was declined, closed early or is being loaded.
    @State private var copyNote: String?

    private var doc: DocRecord? { store.doc(docID) }

    /// Copying all the text is an export like saving or sharing it, so it goes through the same rewarded gate
    /// (and runs straight away when no ad is available).
    private func requestCopy(_ doc: DocRecord) {
        copyNote = nil
        RewardedGate.shared.requestExport({
            UIPasteboard.general.string = ExportBuilder.text(doc: doc).flatMap { String(data: $0.data, encoding: .utf8) }
            copied = true
            copyNote = nil
            APHaptics.success()
        }, onCancel: { reason in
            copyNote = reason.message
            FoliaAnnounce.post(reason.message)
        }, onWaiting: { waiting in
            copyNote = waiting ? "Getting the next ad ready" : nil
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AP.Space.l) {
                ToolHeader(title: "Text", subtitle: "Read on this device. Nothing is uploaded.")
                if working {
                    HStack(spacing: AP.Space.s) {
                        ProgressView()
                        Text("Reading the pages").font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                    }
                } else if let doc, ExportBuilder.text(doc: doc) == nil {
                    EmptyStateView(symbol: "text.magnifyingglass", title: "No text found", message: "Folia could not read any words on these pages. Try the Black & white look, or scan closer and in better light.")
                        .frame(maxWidth: .infinity)
                } else if let doc {
                    ForEach(Array(doc.pages.enumerated()), id: \.element.id) { index, page in
                        let text = OCREngine.plainText(page.ocr ?? [])
                        if !text.isEmpty {
                            VStack(alignment: .leading, spacing: AP.Space.s) {
                                if doc.pages.count > 1 {
                                    Text("Page \(index + 1)").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                                }
                                Text(text)
                                    .font(AP.Font.body)
                                    .foregroundStyle(AP.Palette.paper)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foliaCard()
                        }
                    }
                    VStack(spacing: AP.Space.s) {
                        Button {
                            requestCopy(doc)
                        } label: { Label(copied ? "Copied" : "Copy all text", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.apSecondaryWide)
                        if let copyNote { StatusLine(text: copyNote, tone: .neutral) }
                        if let file = ExportBuilder.text(doc: doc) {
                            FoliaExportBar(files: [file])
                        }
                    }
                }
            }
            .padding(.horizontal, AP.Space.m)
            .padding(.bottom, AP.Space.xl)
            .readableWidth()
        }
        .apScreen()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.recognizeText(docID: docID)
            working = false
        }
    }
}
