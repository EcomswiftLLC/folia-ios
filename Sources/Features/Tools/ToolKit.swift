import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - A PDF a tool works on

struct PDFInput: Identifiable {
    let id = UUID()
    var name: String
    var document: PDFDocument
    var bytes: Int

    var isLocked: Bool { document.isLocked }
    var pageCount: Int { document.pageCount }

    static func open(url: URL) -> PDFInput? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else { return nil }
        return PDFInput(name: url.deletingPathExtension().lastPathComponent, document: document, bytes: data.count)
    }
}

// MARK: - Running a tool

@MainActor
final class ToolRunner: ObservableObject {
    @Published var working = false
    @Published var files: [ExportFile] = []
    @Published var error: String?

    /// Runs the work away from the main thread. An empty or missing result is shown as an error.
    func run(failure: String = "Could not create the file. Try another PDF.", _ work: @escaping () -> [ExportFile]?) async {
        working = true
        error = nil
        files = []
        let result = await Task.detached(priority: .userInitiated) { work() }.value
        working = false
        if let result, !result.isEmpty {
            files = result
            APHaptics.success()
        } else {
            error = failure
        }
    }

    func reset() {
        files = []
        error = nil
    }
}

/// What a tool shows after it ran: progress, an error, or the finished file with the export buttons.
struct ToolResultView: View {
    @ObservedObject var runner: ToolRunner
    var beforeBytes: Int? = nil
    var workingText = "Working"

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            if runner.working {
                HStack(spacing: AP.Space.s) {
                    ProgressView()
                    Text(workingText).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                }
            }
            if let error = runner.error {
                StatusLine(text: error, tone: .failure)
            }
            if !runner.files.isEmpty {
                VStack(alignment: .leading, spacing: AP.Space.m) {
                    HStack(alignment: .top, spacing: AP.Space.m) {
                        if runner.files[0].kind == .pdf {
                            FilePreview(file: runner.files[0])
                                .frame(width: 64, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runner.files.count == 1 ? runner.files[0].filename : "\(runner.files.count) files")
                                .font(AP.Font.headline)
                                .foregroundStyle(AP.Palette.paper)
                                .lineLimit(2)
                            Text(sizeText).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(AP.Font.label)
                                .foregroundStyle(AP.Palette.success)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    FoliaExportBar(files: runner.files)
                }
                .foliaCard()
            }
        }
    }

    private var sizeText: String {
        let total = runner.files.reduce(0) { $0 + $1.data.count }
        if let beforeBytes, beforeBytes > 0, runner.files.count == 1 {
            let saved = Int((1 - Double(total) / Double(beforeBytes)) * 100)
            if saved > 0 { return "\(ByteText.string(beforeBytes)) to \(ByteText.string(total)), \(saved)% smaller" }
        }
        return ByteText.string(total)
    }
}

private struct FilePreview: View {
    let file: ExportFile
    @State private var document: PDFDocument?

    var body: some View {
        Group {
            if let document { PDFPageThumb(document: document, index: 0, width: 80) } else { AP.Palette.sheet }
        }
        .task(id: file.id) { document = PDFDocument(data: file.data) }
    }
}

// MARK: - Choosing the PDF to work on

struct PDFSourcePicker: View {
    @EnvironmentObject private var store: DocStore
    @Binding var inputs: [PDFInput]
    var allowsMultiple = false
    /// Password protected PDFs are only useful to the tool that removes the password.
    var acceptLocked = false
    var initialDoc: UUID? = nil

    @State private var showFiles = false
    @State private var showLibrary = false
    @State private var message: String?
    @State private var loadingLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            HStack(spacing: AP.Space.s) {
                Button { showFiles = true } label: { Label(allowsMultiple ? "Add PDF" : "Choose PDF", systemImage: "doc.badge.plus") }
                    .buttonStyle(.apSecondaryWide)
                Button { showLibrary = true } label: {
                    HStack(spacing: 6) {
                        if loadingLibrary { ProgressView() }
                        Label("My scans", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.apSecondaryWide)
                .disabled(loadingLibrary)
            }
            ForEach(Array(inputs.enumerated()), id: \.element.id) { index, input in
                row(input, index: index)
            }
            if let message { StatusLine(text: message, tone: .failure) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf], allowsMultipleSelection: allowsMultiple) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryPickerSheet { id in Task { await addLibrary(id) } }
        }
        .task {
            if let initialDoc, inputs.isEmpty { await addLibrary(initialDoc) }
        }
    }

    private func row(_ input: PDFInput, index: Int) -> some View {
        HStack(spacing: AP.Space.m) {
            PDFPageThumb(document: input.document, index: 0, width: 60)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                .overlay { if input.isLocked { Image(systemName: "lock.fill").foregroundStyle(AP.Palette.brass) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(input.name).font(AP.Font.headline).foregroundStyle(AP.Palette.paper).lineLimit(1)
                Text(input.isLocked ? "Password protected" : "\(FoliaText.pages(input.pageCount)), \(ByteText.string(input.bytes))")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            Spacer(minLength: 0)
            if allowsMultiple && inputs.count > 1 {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 44) }
                    .disabled(index == 0)
                    .accessibilityLabel(Text("Move \(input.name) up"))
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 44) }
                    .disabled(index == inputs.count - 1)
                    .accessibilityLabel(Text("Move \(input.name) down"))
            }
            Button { inputs.removeAll { $0.id == input.id } } label: { Image(systemName: "xmark.circle.fill").frame(width: 36, height: 44) }
                .foregroundStyle(AP.Palette.mist)
                .accessibilityLabel(Text("Remove \(input.name)"))
        }
        .foregroundStyle(AP.Palette.brass)
        .foliaCard(padding: AP.Space.s + 4)
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard inputs.indices.contains(index), inputs.indices.contains(target) else { return }
        inputs.swapAt(index, target)
    }

    private func add(_ input: PDFInput) {
        message = nil
        if input.isLocked && !acceptLocked {
            message = "“\(input.name)” is password protected. Remove the password first with Protect and unlock."
            return
        }
        if allowsMultiple { inputs.append(input) } else { inputs = [input] }
    }

    private func addFiles(_ urls: [URL]) {
        message = nil
        var failed = 0
        for url in urls {
            if let input = PDFInput.open(url: url) { add(input) } else { failed += 1 }
        }
        if failed > 0 { message = failed == 1 ? "That file could not be opened as a PDF." : "\(failed) files could not be opened as PDFs." }
    }

    private func addLibrary(_ id: UUID) async {
        guard let doc = store.doc(id) else { return }
        loadingLibrary = true
        defer { loadingLibrary = false }
        let storage = store.storage
        var options = ExportOptions()
        options.quality = .standard
        options.searchable = true
        let file = await Task.detached(priority: .userInitiated) { ExportBuilder.pdf(doc: doc, storage: storage, options: options) }.value
        guard let document = PDFDocument(data: file.data) else {
            message = "That scan could not be prepared."
            return
        }
        add(PDFInput(name: doc.title, document: document, bytes: file.data.count))
    }
}

struct LibraryPickerSheet: View {
    @EnvironmentObject private var store: DocStore
    @Environment(\.dismiss) private var dismiss
    var onPick: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.docs.isEmpty {
                    EmptyStateView(symbol: "doc.viewfinder", title: "No scans yet", message: "Scan or import a document first, then it shows up here.")
                } else {
                    List(store.docs) { doc in
                        Button {
                            onPick(doc.id)
                            dismiss()
                        } label: {
                            HStack(spacing: AP.Space.m) {
                                if let first = doc.pages.first {
                                    PageThumbnail(page: first, pixels: 160)
                                        .frame(width: 44, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper).lineLimit(1)
                                    Text(FoliaText.pages(doc.pages.count)).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                                }
                            }
                        }
                        .listRowBackground(AP.Palette.carbon)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .apScreen()
            .navigationTitle("My scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Page selection grid

/// Pages of a PDF as small pictures that can be ticked.
struct PageSelectionGrid: View {
    let document: PDFDocument
    @Binding var selection: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                APChip(title: "All", selected: selection.count == document.pageCount) { selection = Set(0..<document.pageCount) }
                APChip(title: "None", selected: selection.isEmpty) { selection = [] }
                APChip(title: "Odd", selected: false) { selection = Set((0..<document.pageCount).filter { $0 % 2 == 0 }) }
                APChip(title: "Even", selected: false) { selection = Set((0..<document.pageCount).filter { $0 % 2 == 1 }) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: AP.Space.s)], spacing: AP.Space.s) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    let on = selection.contains(index)
                    Button {
                        if on { selection.remove(index) } else { selection.insert(index) }
                        APHaptics.tap()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            PDFPageThumb(document: document, index: index, width: 90)
                                .aspectRatio(0.74, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? AP.Palette.brass : AP.Palette.line, lineWidth: on ? 3 : 1)
                                )
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(on ? AP.Palette.brass : AP.Palette.mist)
                                .background(Circle().fill(AP.Palette.sheet).padding(2))
                                .padding(6)
                            Text("\(index + 1)")
                                .font(AP.Font.number)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .background(Color.black.opacity(0.6), in: Capsule())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Page \(index + 1)"))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}
