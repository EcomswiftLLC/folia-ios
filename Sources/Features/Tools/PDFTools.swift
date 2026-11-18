import SwiftUI
import PDFKit

// MARK: - Shared scaffolding

struct ToolScroll<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AP.Space.l) {
                ToolHeader(title: title, subtitle: subtitle)
                content()
            }
            .padding(.horizontal, AP.Space.m)
            .padding(.bottom, AP.Space.xl)
            .readableWidth()
        }
        .apScreen()
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A labelled group of options inside a card.
struct OptionBlock<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text(title).font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            content()
            if let footnote { Text(footnote).font(AP.Font.caption).foregroundStyle(AP.Palette.mist) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chips that wrap onto several lines instead of scrolling sideways.
struct WrapChips<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: AP.Space.s) { content() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Merge

struct MergeTool: View {
    var initialDoc: UUID? = nil

    @State private var inputs: [PDFInput] = []
    @StateObject private var runner = ToolRunner()

    var body: some View {
        ToolScroll(title: "Merge PDFs", subtitle: "Combine PDFs into one file, in the order you choose.") {
            PDFSourcePicker(inputs: $inputs, allowsMultiple: true, initialDoc: initialDoc)
            Button { merge() } label: { Label(inputs.count < 2 ? "Merge PDFs" : "Merge \(inputs.count) PDFs", systemImage: "square.stack.3d.up") }
                .buttonStyle(.apPrimaryWide)
                .disabled(inputs.count < 2 || runner.working)
            if inputs.count < 2 {
                StatusLine(text: "Add at least two PDFs.", tone: .neutral)
            }
            ToolResultView(runner: runner, workingText: "Merging")
        }
        .onChange(of: inputs.map(\.id)) { _, _ in runner.reset() }
    }

    private func merge() {
        let documents = inputs.map { $0.workingCopy() }
        Task {
            await runner.run {
                let merged = PDFOps.merge(documents)
                guard merged.pageCount > 0, let data = merged.dataRepresentation() else { return nil }
                return [ExportFile(data: data, filename: "Merged.pdf", kind: .pdf)]
            }
        }
    }
}

// MARK: - Split

struct SplitTool: View {
    var initialDoc: UUID? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case extract, remove, each
        var id: String { rawValue }
        var title: String {
            switch self {
            case .extract: return "Extract"
            case .remove: return "Remove"
            case .each: return "Every page"
            }
        }
    }

    @State private var inputs: [PDFInput] = []
    @State private var selection: Set<Int> = []
    @State private var mode: Mode = .extract
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }

    var body: some View {
        ToolScroll(title: "Split PDF", subtitle: "Pull out pages, remove pages, or save every page as its own file.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode != .each {
                    Text(mode == .extract ? "Tick the pages to keep in a new PDF." : "Tick the pages to take out.")
                        .font(AP.Font.callout)
                        .foregroundStyle(AP.Palette.mist)
                    PageSelectionGrid(document: input.document, selection: $selection)
                }

                Button { run(input) } label: { Label(buttonTitle(input), systemImage: "scissors") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(!canRun(input) || runner.working)
                ToolResultView(runner: runner, workingText: "Splitting")
            }
        }
        .onChange(of: inputs.first?.id) { _, _ in
            selection = []
            runner.reset()
        }
        .onChange(of: mode) { _, _ in runner.reset() }
        .onChange(of: selection) { _, _ in runner.reset() }
    }

    private func canRun(_ input: PDFInput) -> Bool {
        switch mode {
        case .extract: return !selection.isEmpty
        case .remove: return !selection.isEmpty && selection.count < input.pageCount
        case .each: return input.pageCount > 1
        }
    }

    private func buttonTitle(_ input: PDFInput) -> String {
        switch mode {
        case .extract: return selection.isEmpty ? "Extract pages" : "Extract \(FoliaText.pages(selection.count))"
        case .remove: return selection.isEmpty ? "Remove pages" : "Remove \(FoliaText.pages(selection.count))"
        case .each: return "Save \(input.pageCount) files"
        }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let chosen = selection.sorted()
        let wanted = mode
        let count = input.pageCount
        Task {
            await runner.run {
                switch wanted {
                case .extract:
                    guard let data = PDFOps.extract(document, pages: chosen).dataRepresentation() else { return nil }
                    return [ExportFile(data: data, filename: "\(base) extract.pdf", kind: .pdf)]
                case .remove:
                    let keep = (0..<count).filter { !chosen.contains($0) }
                    guard let data = PDFOps.extract(document, pages: keep).dataRepresentation() else { return nil }
                    return [ExportFile(data: data, filename: "\(base) edited.pdf", kind: .pdf)]
                case .each:
                    var files: [ExportFile] = []
                    for index in 0..<count {
                        guard let data = PDFOps.extract(document, pages: [index]).dataRepresentation() else { continue }
                        files.append(ExportFile(data: data, filename: "\(base)-\(index + 1).pdf", kind: .pdf))
                    }
                    return files
                }
            }
        }
    }
}

// MARK: - Compress

struct CompressTool: View {
    var initialDoc: UUID? = nil

    @State private var inputs: [PDFInput] = []
    @State private var level: CompressionLevel = .medium
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }

    var body: some View {
        ToolScroll(title: "Compress PDF", subtitle: "Make a PDF small enough to email or upload.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                OptionBlock(title: "Size", footnote: "\(level.detail). Pages become pictures, so text can no longer be selected.") {
                    WrapChips {
                        ForEach(CompressionLevel.allCases) { option in
                            APChip(title: option.title, selected: level == option) { level = option }
                        }
                    }
                }
                .foliaCard()
                Button { run(input) } label: { Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(runner.working)
                ToolResultView(runner: runner, beforeBytes: input.bytes, workingText: "Compressing")
                if let file = runner.files.first, file.data.count >= input.bytes {
                    StatusLine(text: "This PDF is already small. Try a smaller size.", tone: .neutral)
                }
            }
        }
        .onChange(of: inputs.first?.id) { _, _ in runner.reset() }
        .onChange(of: level) { _, _ in runner.reset() }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let chosen = level
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        Task {
            await runner.run {
                guard let data = PDFOps.compress(document, level: chosen) else { return nil }
                return [ExportFile(data: data, filename: "\(base) small.pdf", kind: .pdf)]
            }
        }
    }
}

// MARK: - Page numbers

struct NumbersTool: View {
    var initialDoc: UUID? = nil

    @State private var inputs: [PDFInput] = []
    @State private var position: NumberPosition = .bottomCenter
    @State private var format: NumberFormat = .pageOfTotal
    @State private var start = 1
    @State private var skipFirst = false
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }

    var body: some View {
        ToolScroll(title: "Page numbers", subtitle: "Add a number to every page of a PDF.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                VStack(alignment: .leading, spacing: AP.Space.m) {
                    OptionBlock(title: "Position") {
                        WrapChips {
                            ForEach(NumberPosition.allCases) { option in
                                APChip(title: option.title, selected: position == option) { position = option }
                            }
                        }
                    }
                    OptionBlock(title: "Style") {
                        WrapChips {
                            ForEach(NumberFormat.allCases) { option in
                                APChip(title: option.title, selected: format == option) { format = option }
                            }
                        }
                    }
                    Stepper("Start at \(start)", value: $start, in: 1...999)
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.paper)
                    Toggle("Leave the first page blank", isOn: $skipFirst)
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.paper)
                        .tint(AP.Palette.brass)
                }
                .foliaCard()
                Button { run(input) } label: { Label("Add numbers", systemImage: "number") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(runner.working)
                ToolResultView(runner: runner, workingText: "Numbering the pages")
            }
        }
        .onChange(of: inputs.first?.id) { _, _ in runner.reset() }
        .onChange(of: position) { _, _ in runner.reset() }
        .onChange(of: format) { _, _ in runner.reset() }
        .onChange(of: start) { _, _ in runner.reset() }
        .onChange(of: skipFirst) { _, _ in runner.reset() }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let overlay = PDFOverlays.pageNumbers(
            total: document.pageCount, position: position, format: format,
            start: start, skipFirst: skipFirst, fontSize: 11, color: UIColor(white: 0.25, alpha: 1)
        )
        Task {
            await runner.run {
                guard let data = PDFOps.render(document, overlay: overlay) else { return nil }
                return [ExportFile(data: data, filename: "\(base) numbered.pdf", kind: .pdf)]
            }
        }
    }
}

// MARK: - Watermark

struct WatermarkTool: View {
    var initialDoc: UUID? = nil

    enum Tint: String, CaseIterable, Identifiable {
        case grey, red, blue, black
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var color: UIColor {
            switch self {
            case .grey: return UIColor(white: 0.45, alpha: 1)
            case .red: return UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
            case .blue: return UIColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
            case .black: return .black
            }
        }
    }

    @State private var inputs: [PDFInput] = []
    @State private var text = ""
    @State private var tint: Tint = .grey
    @State private var opacity = 0.25
    @State private var diagonal = true
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ToolScroll(title: "Watermark", subtitle: "Stamp words such as DRAFT or CONFIDENTIAL across every page.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                VStack(alignment: .leading, spacing: AP.Space.m) {
                    OptionBlock(title: "Text") {
                        TextField("For example DRAFT", text: $text)
                            .textInputAutocapitalization(.characters)
                            .padding(12)
                            .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                            .foregroundStyle(AP.Palette.paper)
                    }
                    OptionBlock(title: "Colour") {
                        WrapChips {
                            ForEach(Tint.allCases) { option in
                                APChip(title: option.title, selected: tint == option) { tint = option }
                            }
                        }
                    }
                    OptionBlock(title: "Layout") {
                        WrapChips {
                            APChip(title: "Diagonal", selected: diagonal) { diagonal = true }
                            APChip(title: "Straight", selected: !diagonal) { diagonal = false }
                        }
                    }
                    OptionBlock(title: "Strength \(Int(opacity * 100))%") {
                        Slider(value: $opacity, in: 0.1...0.6)
                            .tint(AP.Palette.brass)
                            .accessibilityLabel(Text("Strength"))
                    }
                }
                .foliaCard()
                Button { run(input) } label: { Label("Add watermark", systemImage: "drop") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(trimmed.isEmpty || runner.working)
                ToolResultView(runner: runner, workingText: "Stamping the pages")
            }
        }
        .onChange(of: inputs.first?.id) { _, _ in runner.reset() }
        .onChange(of: text) { _, _ in runner.reset() }
        .onChange(of: tint) { _, _ in runner.reset() }
        .onChange(of: opacity) { _, _ in runner.reset() }
        .onChange(of: diagonal) { _, _ in runner.reset() }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let size: CGFloat = trimmed.count > 12 ? 0.07 : (trimmed.count > 7 ? 0.11 : 0.16)
        let overlay = PDFOverlays.watermark(text: trimmed, color: tint.color, opacity: opacity, sizeFraction: size, angleDegrees: diagonal ? -35 : 0)
        Task {
            await runner.run {
                guard let data = PDFOps.render(document, overlay: overlay) else { return nil }
                return [ExportFile(data: data, filename: "\(base) watermarked.pdf", kind: .pdf)]
            }
        }
    }
}

// MARK: - Password

struct LockTool: View {
    var initialDoc: UUID? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case lock, unlock
        var id: String { rawValue }
        var title: String { self == .lock ? "Add password" : "Remove password" }
    }

    @State private var inputs: [PDFInput] = []
    @State private var mode: Mode = .lock
    @State private var password = ""
    @State private var confirm = ""
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }

    private var canRun: Bool {
        guard let input, !runner.working else { return false }
        switch mode {
        case .lock: return !input.isLocked && password.count >= 4 && password == confirm
        case .unlock: return input.isLocked && !password.isEmpty
        }
    }

    var body: some View {
        ToolScroll(title: "Protect and unlock", subtitle: "Lock a PDF with a password, or remove the password from one you can open.") {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            PDFSourcePicker(inputs: $inputs, acceptLocked: true, initialDoc: initialDoc)

            if let input {
                VStack(alignment: .leading, spacing: AP.Space.m) {
                    if mode == .lock && input.isLocked {
                        StatusLine(text: "This PDF already has a password. Use Remove password first.", tone: .failure)
                    } else if mode == .unlock && !input.isLocked {
                        StatusLine(text: "This PDF has no password.", tone: .neutral)
                    }
                    SecureField(mode == .lock ? "New password (4 or more characters)" : "Password", text: $password)
                        .textContentType(.password)
                        .padding(12)
                        .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                        .foregroundStyle(AP.Palette.paper)
                    if mode == .lock {
                        SecureField("Repeat password", text: $confirm)
                            .padding(12)
                            .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                            .foregroundStyle(AP.Palette.paper)
                        if !confirm.isEmpty && confirm != password {
                            StatusLine(text: "The two passwords don’t match.", tone: .failure)
                        }
                        Text("Keep the password safe. Folia can’t recover it for you.")
                            .font(AP.Font.caption)
                            .foregroundStyle(AP.Palette.mist)
                    }
                }
                .foliaCard()
                Button { run(input) } label: {
                    Label(mode == .lock ? "Lock PDF" : "Remove password", systemImage: mode == .lock ? "lock" : "lock.open")
                }
                .buttonStyle(.apPrimaryWide)
                .disabled(!canRun)
                ToolResultView(runner: runner, workingText: mode == .lock ? "Locking" : "Unlocking")
            }
        }
        .onChange(of: mode) { _, _ in
            password = ""
            confirm = ""
            runner.reset()
        }
        .onChange(of: inputs.first?.id) { _, _ in runner.reset() }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let secret = password
        switch mode {
        case .lock:
            Task {
                await runner.run {
                    guard let data = PDFOps.lock(document, password: secret) else { return nil }
                    return [ExportFile(data: data, filename: "\(base) protected.pdf", kind: .pdf)]
                }
            }
        case .unlock:
            guard document.unlock(withPassword: secret) else {
                runner.error = "That password did not open the PDF. Check it and try again."
                return
            }
            Task {
                await runner.run {
                    guard let data = PDFOps.render(document) else { return nil }
                    return [ExportFile(data: data, filename: "\(base) unlocked.pdf", kind: .pdf)]
                }
            }
        }
    }
}

// MARK: - PDF to pictures

struct PDFImagesTool: View {
    var initialDoc: UUID? = nil

    enum Size: String, CaseIterable, Identifiable {
        case small, standard, high
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var side: CGFloat {
            switch self {
            case .small: return 1200
            case .standard: return 1800
            case .high: return 2600
            }
        }
    }

    @State private var inputs: [PDFInput] = []
    @State private var format: OutputFormat = .jpeg
    @State private var size: Size = .standard
    @StateObject private var runner = ToolRunner()

    private var input: PDFInput? { inputs.first }

    var body: some View {
        ToolScroll(title: "PDF to pictures", subtitle: "Turn every page of a PDF into a picture.") {
            PDFSourcePicker(inputs: $inputs, initialDoc: initialDoc)
            if let input {
                VStack(alignment: .leading, spacing: AP.Space.m) {
                    OptionBlock(title: "Format") {
                        WrapChips {
                            APChip(title: "JPG", selected: format == .jpeg) { format = .jpeg }
                            APChip(title: "PNG", selected: format == .png) { format = .png }
                        }
                    }
                    OptionBlock(title: "Size") {
                        WrapChips {
                            ForEach(Size.allCases) { option in
                                APChip(title: option.title, selected: size == option) { size = option }
                            }
                        }
                    }
                }
                .foliaCard()
                Button { run(input) } label: { Label("Make \(FoliaText.pages(input.pageCount).replacingOccurrences(of: "page", with: "picture"))", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.apPrimaryWide)
                    .disabled(runner.working)
                ToolResultView(runner: runner, workingText: "Rendering the pages")
            }
        }
        .onChange(of: inputs.first?.id) { _, _ in runner.reset() }
        .onChange(of: format) { _, _ in runner.reset() }
        .onChange(of: size) { _, _ in runner.reset() }
    }

    private func run(_ input: PDFInput) {
        let document = input.workingCopy()
        let base = ExportFile.safeName(input.name, fallback: "PDF")
        let chosenFormat = format
        let side = size.side
        Task {
            await runner.run {
                var files: [ExportFile] = []
                for index in 0..<document.pageCount {
                    autoreleasepool {
                        guard let image = PDFOps.images(document, pages: [index], maxSide: side).first,
                              let data = ImageCodec.encode(image, format: chosenFormat, quality: 0.88) else { return }
                        let suffix = document.pageCount > 1 ? "-\(index + 1)" : ""
                        files.append(ExportFile(
                            data: data,
                            filename: "\(base)\(suffix).\(chosenFormat.fileExtension)",
                            kind: chosenFormat == .png ? .png : .jpeg
                        ))
                    }
                }
                return files
            }
        }
    }
}
