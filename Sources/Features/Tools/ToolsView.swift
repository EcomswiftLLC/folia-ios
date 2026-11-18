import SwiftUI
import PhotosUI

// MARK: - Hub

enum ToolKind: String, CaseIterable, Identifiable, Hashable {
    case scan, photos, idcard
    case merge, split, compress
    case sign, numbers, watermark
    case pdfImages, text, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan pages"
        case .photos: return "Photos to PDF"
        case .idcard: return "ID card copy"
        case .merge: return "Merge PDFs"
        case .split: return "Split PDF"
        case .compress: return "Compress PDF"
        case .sign: return "Sign and fill"
        case .numbers: return "Page numbers"
        case .watermark: return "Watermark"
        case .pdfImages: return "PDF to pictures"
        case .text: return "Extract text"
        case .lock: return "Protect and unlock"
        }
    }

    var blurb: String {
        switch self {
        case .scan: return "Use the camera"
        case .photos: return "Turn pictures into pages"
        case .idcard: return "Front and back on one sheet"
        case .merge: return "Join files in any order"
        case .split: return "Extract or remove pages"
        case .compress: return "Shrink for email"
        case .sign: return "Signature, date and text"
        case .numbers: return "Number every page"
        case .watermark: return "DRAFT, CONFIDENTIAL"
        case .pdfImages: return "One JPG or PNG per page"
        case .text: return "Copy words from a scan"
        case .lock: return "Add or remove a password"
        }
    }

    var symbol: String {
        switch self {
        case .scan: return "camera.viewfinder"
        case .photos: return "photo.on.rectangle.angled"
        case .idcard: return "person.text.rectangle"
        case .merge: return "square.stack.3d.up"
        case .split: return "scissors"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .sign: return "signature"
        case .numbers: return "number"
        case .watermark: return "drop"
        case .pdfImages: return "photo.stack"
        case .text: return "text.viewfinder"
        case .lock: return "lock"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .idcard: IDCardTool()
        case .merge: MergeTool()
        case .split: SplitTool()
        case .compress: CompressTool()
        case .sign: SignTool()
        case .numbers: NumbersTool()
        case .watermark: WatermarkTool()
        case .pdfImages: PDFImagesTool()
        case .text: ExtractTextEntry()
        case .lock: LockTool()
        case .scan, .photos: EmptyView()
        }
    }
}

struct ToolsView: View {
    @EnvironmentObject private var importer: ImportController

    private let groups: [(title: String, tools: [ToolKind])] = [
        ("Create", [.scan, .photos, .idcard]),
        ("Organise", [.merge, .split, .compress]),
        ("Edit", [.sign, .numbers, .watermark]),
        ("Convert and protect", [.pdfImages, .text, .lock]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Tools", subtitle: "Work on any PDF. Everything runs on your device.")
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: AP.Space.s) {
                            APSectionTitle(text: group.title)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: AP.Space.s), GridItem(.flexible(), spacing: AP.Space.s)], spacing: AP.Space.s) {
                                ForEach(group.tools) { tool in
                                    switch tool {
                                    case .scan:
                                        Button { importer.scan() } label: { ToolTile(tool: tool) }.buttonStyle(.plain)
                                    case .photos:
                                        Button { importer.choosePhotos() } label: { ToolTile(tool: tool) }.buttonStyle(.plain)
                                    default:
                                        NavigationLink(value: tool) { ToolTile(tool: tool) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.l)
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ToolKind.self) { $0.destination }
            .navigationDestination(for: ToolRoute.self) { $0.destination }
        }
    }
}

struct ToolTile: View {
    let tool: ToolKind

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Image(systemName: tool.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 44, height: 44)
                .background(AP.Palette.brass.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper).lineLimit(2).minimumScaleFactor(0.85)
                Text(tool.blurb).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .foliaCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Extract text entry

/// Text recognition works on documents in the library, so this lists them, or helps bring one in.
struct ExtractTextEntry: View {
    @EnvironmentObject private var store: DocStore
    @EnvironmentObject private var importer: ImportController

    var body: some View {
        ToolScroll(title: "Extract text", subtitle: "Pick a scan to read the words on its pages.") {
            if store.docs.isEmpty {
                EmptyStateView(symbol: "text.viewfinder", title: "Nothing to read yet", message: "Scan a page or import a PDF or photo, then come back to copy its text.")
                    .frame(maxWidth: .infinity)
                VStack(spacing: AP.Space.s) {
                    Button { importer.scan() } label: { Label("Scan a page", systemImage: "camera.viewfinder") }
                        .buttonStyle(.apPrimaryWide)
                    HStack(spacing: AP.Space.s) {
                        Button { importer.choosePhotos() } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                            .buttonStyle(.apSecondaryWide)
                        Button { importer.chooseFiles() } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(.apSecondaryWide)
                    }
                }
            } else {
                VStack(spacing: AP.Space.s) {
                    ForEach(store.docs) { doc in
                        NavigationLink(value: ToolRoute.text(doc.id)) {
                            HStack(spacing: AP.Space.m) {
                                if let first = doc.pages.first {
                                    PageThumbnail(page: first, pixels: 160)
                                        .frame(width: 44, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper).lineLimit(2)
                                    Text(FoliaText.pages(doc.pages.count)).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(AP.Palette.mist)
                            }
                            .foliaCard(padding: AP.Space.s + 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - ID card copy

struct IDCardTool: View {
    @State private var frontItem: PhotosPickerItem?
    @State private var backItem: PhotosPickerItem?
    @State private var front: CGImage?
    @State private var back: CGImage?
    /// Card edges found in each photo. nil while a chosen photo has no usable edges.
    @State private var frontQuad: Quad?
    @State private var backQuad: Quad?
    @State private var loadingCard = false
    @State private var page: PageSizeOption = .a4
    @State private var enhance = true
    @State private var asPDF = true
    @StateObject private var runner = ToolRunner()

    var body: some View {
        ToolScroll(title: "ID card copy", subtitle: "Put both sides of a card on one sheet at its real size, ready to print or send.") {
            HStack(spacing: AP.Space.s) {
                CardSlot(title: "Front", image: front, item: $frontItem)
                CardSlot(title: "Back (optional)", image: back, item: $backItem)
            }
            VStack(alignment: .leading, spacing: AP.Space.m) {
                OptionBlock(title: "Sheet") {
                    WrapChips {
                        APChip(title: "A4", selected: page == .a4) { page = .a4 }
                        APChip(title: "US Letter", selected: page == .letter) { page = .letter }
                    }
                }
                OptionBlock(title: "File") {
                    WrapChips {
                        APChip(title: "PDF", selected: asPDF) { asPDF = true }
                        APChip(title: "JPG picture", selected: !asPDF) { asPDF = false }
                    }
                }
                Toggle("Straighten and clean up", isOn: $enhance)
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
                    .tint(AP.Palette.brass)
            }
            .foliaCard()
            Button { run() } label: { Label("Create copy sheet", systemImage: "person.text.rectangle") }
                .buttonStyle(.apPrimaryWide)
                .disabled(!canCreate || runner.working || loadingCard)
            if loadingCard {
                HStack(spacing: AP.Space.s) {
                    ProgressView()
                    Text("Finding the card edges").font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                }
            }
            if front == nil {
                StatusLine(text: "Choose a photo of the front of the card.", tone: .neutral)
            } else if frontQuad == nil && !loadingCard {
                StatusLine(text: "Front: \(Self.noEdgesText)", tone: .failure)
            }
            if back != nil && backQuad == nil && !loadingCard {
                StatusLine(text: "Back: \(Self.noEdgesText)", tone: .failure)
            }
            ToolResultView(runner: runner, workingText: "Building the sheet")
        }
        .onChange(of: frontItem) { _, item in
            Task {
                loadingCard = true
                let loaded = await load(item)
                front = loaded.image
                frontQuad = loaded.quad
                loadingCard = false
                runner.reset()
            }
        }
        .onChange(of: backItem) { _, item in
            Task {
                loadingCard = true
                let loaded = await load(item)
                back = loaded.image
                backQuad = loaded.quad
                loadingCard = false
                runner.reset()
            }
        }
    }

    static let noEdgesText = "Could not find the card edges. Use a photo of the card on a plain background."

    /// Both chosen sides have usable card edges.
    private var canCreate: Bool {
        guard front != nil, frontQuad != nil else { return false }
        if back != nil && backQuad == nil { return false }
        return true
    }

    /// Reads the photo and finds the card in it, off the main thread.
    private func load(_ item: PhotosPickerItem?) async -> (image: CGImage?, quad: Quad?) {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return (nil, nil) }
        return await Task.detached(priority: .userInitiated) { () -> (image: CGImage?, quad: Quad?) in
            guard let image = PhotoLoader.decode(data, maxPixel: 2400) else { return (nil, nil) }
            let small = ImageCodec.scaled(image, maxPixel: 900) ?? image
            guard let found = DocumentDetector.detect(small), CardEdges.area(found) >= 0.04 else { return (image, nil) }
            return (image, found)
        }.value
    }
}

/// Helpers for finding an ID card in a photo.
enum CardEdges {
    /// Area of a quad as a fraction of the photo.
    static func area(_ quad: Quad) -> CGFloat {
        let pts = quad.points
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

extension IDCardTool {
    private func run() {
        guard let front, let frontQuad, canCreate else { return }
        let back = back
        let backQuad = backQuad
        let clean = enhance
        let sheetPage = page
        let pdf = asPDF
        Task {
            await runner.run {
                func prepare(_ image: CGImage, _ quad: Quad?) -> CGImage {
                    var out = PageRenderer.render(image, filter: clean ? .auto : .original, quad: quad, quarterTurns: 0, maxSide: 1800) ?? image
                    if out.height > out.width { out = PageRenderer.render(out, filter: .original, quad: nil, quarterTurns: 1) ?? out }
                    return out
                }
                guard let sheet = IDCardComposer.compose(front: prepare(front, frontQuad), back: back.map { prepare($0, backQuad) }, page: sheetPage) else { return nil }
                if pdf {
                    let data = PDFBuilder.makePDF([PDFPageInput(image: sheet)], pageSize: sheetPage, quality: 0.9, title: "ID card copy")
                    return [ExportFile(data: data, filename: "ID card copy.pdf", kind: .pdf)]
                }
                guard let jpeg = ImageCodec.encode(sheet, format: .jpeg, quality: 0.9) else { return nil }
                return [ExportFile(data: jpeg, filename: "ID card copy.jpg", kind: .jpeg)]
            }
        }
    }
}

private struct CardSlot: View {
    let title: String
    let image: CGImage?
    @Binding var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Color.clear
                .aspectRatio(1.586, contentMode: .fit)
                .overlay {
                    ZStack {
                        AP.Palette.carbon
                        if let image {
                            Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFill()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "plus.viewfinder").font(.system(size: 24))
                                Text(title).font(AP.Font.caption).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(AP.Palette.mist)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                        .strokeBorder(AP.Palette.line, style: StrokeStyle(lineWidth: 1, dash: image == nil ? [5, 4] : []))
                )
        }
        .accessibilityLabel(Text(image == nil ? "Choose \(title)" : "\(title) chosen. Double tap to change"))
    }
}
