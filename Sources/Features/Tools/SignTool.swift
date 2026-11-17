import SwiftUI
import PDFKit

// MARK: - Sign and fill

struct SignTool: View {
    var initialDoc: UUID? = nil
    #if DEBUG
    /// Development screenshots start with a signature and a date already placed.
    var demoMarks = false
    #endif

    @State private var inputs: [PDFInput] = []
    @State private var items: [PagePlacement] = []
    @State private var pageIndex = 0
    @State private var selectedID: UUID?
    @State private var pageImage: UIImage?
    @State private var signature: UIImage? = SignatureStore.load()
    @State private var showPad = false
    @State private var askText = false
    @State private var promptText = ""
    @State private var editingID: UUID?
    @State private var dragStart: (id: UUID, center: CGPoint)?
    @StateObject private var runner = ToolRunner()

    private let canvasSpace = "signCanvas"

    private var input: PDFInput? { inputs.first }
    private var pageWidthPoints: CGFloat {
        guard let page = input?.document.page(at: pageIndex) else { return 600 }
        return max(1, PDFOps.pageSize(page).width)
    }
    private var pageAspect: CGFloat {
        guard let page = input?.document.page(at: pageIndex) else { return 0.74 }
        let size = PDFOps.pageSize(page)
        return size.height > 0 ? size.width / size.height : 0.74
    }
    private var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }

    var body: some View {
        ToolScroll(title: "Sign and fill", subtitle: "Place your signature, a date or typed text anywhere on a PDF.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                pager(input)
                canvas(input)
                addBar
                if selectedIndex != nil { selectedControls }
                Button { run(input) } label: { Label("Save signed PDF", systemImage: "checkmark.seal") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(items.isEmpty || runner.working)
                if items.isEmpty {
                    StatusLine(text: "Add a signature, text or date, then drag it into place.", tone: .neutral)
                }
                ToolResultView(runner: runner, workingText: "Placing your marks")
            }
        }
        .sheet(isPresented: $showPad) {
            SignaturePad { image in
                SignatureStore.save(image)
                signature = image
                addSignature(image)
            }
        }
        .alert(editingID == nil ? "Add text" : "Edit text", isPresented: $askText) {
            TextField("Text", text: $promptText)
            Button("Done") { commitText() }
            Button("Cancel", role: .cancel) { editingID = nil }
        }
        .onChange(of: inputs.first?.id) { _, _ in
            items = []
            selectedID = nil
            pageIndex = 0
            pageImage = nil
            runner.reset()
            #if DEBUG
            if demoMarks { seedDemoMarks() }
            #endif
        }
        .onChange(of: items.count) { _, _ in runner.reset() }
    }

    // MARK: Page

    private func pager(_ input: PDFInput) -> some View {
        HStack {
            Button { pageIndex = max(0, pageIndex - 1); selectedID = nil } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(pageIndex == 0)
            .accessibilityLabel(Text("Previous page"))
            Spacer()
            Text("Page \(pageIndex + 1) of \(input.pageCount)")
                .font(AP.Font.number)
                .foregroundStyle(AP.Palette.paper)
            Spacer()
            Button { pageIndex = min(input.pageCount - 1, pageIndex + 1); selectedID = nil } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(pageIndex >= input.pageCount - 1)
            .accessibilityLabel(Text("Next page"))
        }
        .foregroundStyle(AP.Palette.brass)
    }

    private func canvas(_ input: PDFInput) -> some View {
        ZStack {
            AP.Palette.sheet
            if let pageImage {
                Image(uiImage: pageImage).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            GeometryReader { geo in
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = nil }
                    ForEach(items.filter { $0.pageIndex == pageIndex }) { item in
                        itemView(item, size: geo.size)
                    }
                }
                .coordinateSpace(name: canvasSpace)
            }
        }
        .aspectRatio(pageAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .task(id: "\(input.id.uuidString)-\(pageIndex)") {
            let document = input.document
            let index = pageIndex
            let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
                PDFOps.images(document, pages: [index], maxSide: 1400).first.map { UIImage(cgImage: $0) }
            }.value
            pageImage = rendered
        }
    }

    @ViewBuilder
    private func itemView(_ item: PagePlacement, size: CGSize) -> some View {
        let selected = item.id == selectedID
        Group {
            switch item.content {
            case .image(let image):
                Image(uiImage: image).resizable().scaledToFit().frame(width: size.width * item.width)
            case .text(let text, let points, let color):
                Text(text)
                    .font(.system(size: points * size.width / pageWidthPoints))
                    .foregroundColor(Color(color))
                    .fixedSize()
            }
        }
        .padding(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AP.Palette.brass, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .opacity(selected ? 1 : 0)
        )
        .position(x: item.center.x * size.width, y: item.center.y * size.height)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
                .onChanged { value in
                    selectedID = item.id
                    if dragStart?.id != item.id { dragStart = (item.id, item.center) }
                    guard let start = dragStart, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                    items[index].center = CGPoint(
                        x: min(1, max(0, start.center.x + value.translation.width / max(1, size.width))),
                        y: min(1, max(0, start.center.y + value.translation.height / max(1, size.height)))
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture { selectedID = item.id }
        .accessibilityLabel(Text(accessibilityName(item)))
        .accessibilityHint(Text("Double tap to select, then use the size slider or Delete"))
    }

    private func accessibilityName(_ item: PagePlacement) -> String {
        switch item.content {
        case .image: return "Signature"
        case .text(let text, _, _): return "Text, \(text)"
        }
    }

    // MARK: Adding

    private var addBar: some View {
        HStack(spacing: AP.Space.s) {
            addButton("Signature", "signature") {
                if let signature { addSignature(signature) } else { showPad = true }
            }
            addButton("Text", "textformat") {
                editingID = nil
                promptText = ""
                askText = true
            }
            addButton("Date", "calendar") {
                addText(FoliaText.date(Date()), size: 14)
            }
            addButton("Tick", "checkmark") {
                addText("✓", size: 24)
            }
        }
    }

    private func addButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(AP.Font.caption)
            }
            .foregroundStyle(AP.Palette.paper)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func addSignature(_ image: UIImage) {
        let item = PagePlacement(pageIndex: pageIndex, content: .image(image), center: CGPoint(x: 0.5, y: 0.82), width: 0.32)
        items.append(item)
        selectedID = item.id
    }

    private func addText(_ text: String, size: CGFloat) {
        let item = PagePlacement(pageIndex: pageIndex, content: .text(text, size: size, color: .black), center: CGPoint(x: 0.5, y: 0.5), width: 0.3)
        items.append(item)
        selectedID = item.id
    }

    private func commitText() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { editingID = nil }
        guard !text.isEmpty else { return }
        if let editingID, let index = items.firstIndex(where: { $0.id == editingID }), case .text(_, let size, let color) = items[index].content {
            items[index].content = .text(text, size: size, color: color)
        } else if editingID == nil {
            addText(text, size: 16)
        }
    }

    // MARK: Selected item

    private var selectedControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            if let index = selectedIndex {
                switch items[index].content {
                case .image:
                    Text("Signature size").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                    Slider(value: Binding(get: { items[index].width }, set: { items[index].width = $0 }), in: 0.08...0.7)
                        .tint(AP.Palette.brass)
                        .accessibilityLabel(Text("Signature size"))
                case .text(let text, let size, let color):
                    Text("Text size").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                    Slider(
                        value: Binding(get: { size }, set: { items[index].content = .text(text, size: $0, color: color) }),
                        in: 8...64
                    )
                    .tint(AP.Palette.brass)
                    .accessibilityLabel(Text("Text size"))
                }
                HStack(spacing: AP.Space.s) {
                    if case .text(let text, _, _) = items[index].content {
                        Button {
                            editingID = items[index].id
                            promptText = text
                            askText = true
                        } label: { Label("Edit text", systemImage: "pencil") }
                            .buttonStyle(.apSecondaryWide)
                    }
                    if case .image = items[index].content {
                        Button { showPad = true } label: { Label("New signature", systemImage: "signature") }
                            .buttonStyle(.apSecondaryWide)
                    }
                    Button {
                        let id = items[index].id
                        items.removeAll { $0.id == id }
                        selectedID = nil
                    } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(.apSecondaryWide)
                }
            }
        }
        .foliaCard()
    }

    #if DEBUG
    private func seedDemoMarks() {
        var points: [CGPoint] = []
        for step in 0..<140 {
            let t = Double(step)
            points.append(CGPoint(x: t * 2.6 + 10 * sin(t / 4), y: 60 + 34 * sin(t / 7) * cos(t / 23) + 8 * sin(t / 2.1)))
        }
        if let image = SignaturePad.image(from: [points]) {
            items.append(PagePlacement(pageIndex: 0, content: .image(image), center: CGPoint(x: 0.7, y: 0.86), width: 0.3))
        }
        let date = PagePlacement(pageIndex: 0, content: .text("17 Nov 2026", size: 13, color: .black), center: CGPoint(x: 0.22, y: 0.9), width: 0.3)
        items.append(date)
        selectedID = items.first?.id
    }
    #endif

    // MARK: Output

    private func run(_ input: PDFInput) {
        let document = input.document
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let overlay = PDFOverlays.placements(items)
        selectedID = nil
        Task {
            await runner.run {
                guard let data = PDFOps.render(document, overlay: overlay) else { return nil }
                return [ExportFile(data: data, filename: "\(base) signed.pdf", kind: .pdf)]
            }
        }
    }
}

// MARK: - Signature pad

struct SignaturePad: View {
    var onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    private static let ink = UIColor(red: 0.07, green: 0.12, blue: 0.42, alpha: 1)

    var body: some View {
        NavigationStack {
            VStack(spacing: AP.Space.m) {
                Text("Sign with your finger. Your signature stays on this device and is only used on your own documents.")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                ZStack(alignment: .bottomLeading) {
                    AP.Palette.sheet
                    Canvas { context, _ in
                        for stroke in strokes + [current] where stroke.count > 1 {
                            context.stroke(
                                Path(Self.smooth(stroke)),
                                with: .color(Color(Self.ink)),
                                style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, AP.Space.m).padding(.bottom, 52)
                    Text("Sign above the line").font(AP.Font.caption).foregroundStyle(Color.gray).padding(AP.Space.m)
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { current.append($0.location) }
                        .onEnded { _ in
                            if current.count > 1 { strokes.append(current) }
                            current = []
                        }
                )
                .accessibilityLabel(Text("Signature area"))
                HStack(spacing: AP.Space.s) {
                    Button { strokes = []; current = [] } label: { Label("Clear", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.apSecondaryWide)
                        .disabled(strokes.isEmpty)
                    Button {
                        if let image = Self.image(from: strokes) {
                            onSave(image)
                            dismiss()
                        }
                    } label: { Label("Use signature", systemImage: "checkmark") }
                        .buttonStyle(.apPrimaryWide)
                        .disabled(strokes.isEmpty)
                }
                Spacer()
            }
            .padding(AP.Space.m)
            .apScreen()
            .navigationTitle("Your signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    /// A smooth line through the touched points.
    static func smooth(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The signature alone, cropped to its ink, on a transparent background.
    static func image(from strokes: [[CGPoint]]) -> UIImage? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return nil }
        let pad: CGFloat = 8
        let size = CGSize(width: max(20, maxX - minX) + pad * 2, height: max(20, maxY - minY) + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: pad - minX, y: pad - minY)
            cg.setStrokeColor(ink.cgColor)
            cg.setLineWidth(3.2)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                cg.addPath(smooth(stroke))
                cg.strokePath()
            }
        }
    }
}
