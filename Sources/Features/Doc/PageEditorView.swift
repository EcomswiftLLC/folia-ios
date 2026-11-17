import SwiftUI

struct PageEditorView: View {
    let docID: UUID
    let startPage: UUID

    @EnvironmentObject private var store: DocStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: UUID
    @State private var showCrop = false
    @State private var confirmDelete = false

    init(docID: UUID, startPage: UUID) {
        self.docID = docID
        self.startPage = startPage
        _selected = State(initialValue: startPage)
    }

    private var pages: [PageRecord] { store.doc(docID)?.pages ?? [] }
    private var current: PageRecord? { pages.first { $0.id == selected } }
    private var currentIndex: Int { pages.firstIndex { $0.id == selected } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if pages.isEmpty {
                Color.clear.onAppear { dismiss() }
            } else {
                TabView(selection: $selected) {
                    ForEach(pages) { page in
                        PagePreview(page: page).tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(AP.Palette.graphite)
                if let current {
                    controls(current)
                }
            }
        }
        .apScreen()
        .navigationTitle("Page \(currentIndex + 1) of \(max(pages.count, 1))")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCrop) {
            if let current { CropView(docID: docID, pageID: current.id) }
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete page", role: .destructive) { deleteCurrent() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The page is removed from this document. This can’t be undone.")
        }
    }

    private func controls(_ page: PageRecord) -> some View {
        VStack(spacing: AP.Space.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AP.Space.s) {
                    ForEach(ScanFilter.allCases) { filter in
                        FilterTile(page: page, filter: filter, selected: page.filter == filter) {
                            APHaptics.tap()
                            store.updatePage(docID, page.id) { $0.filter = filter }
                        }
                    }
                }
                .padding(.horizontal, AP.Space.m)
            }
            HStack(spacing: 0) {
                action("Crop", "crop") { showCrop = true }
                action("Rotate", "rotate.right") { store.rotate(docID, page.id, by: 1) }
                if pages.count > 1 {
                    action("All pages", "square.on.square") { store.setFilterForAll(docID, page.filter) }
                }
                action("Delete", "trash", destructive: true) { confirmDelete = true }
            }
            .padding(.horizontal, AP.Space.s)
        }
        .padding(.top, AP.Space.m)
        .padding(.bottom, AP.Space.s)
        .background(AP.Palette.lens)
    }

    private func action(_ title: String, _ symbol: String, destructive: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                Text(title).font(AP.Font.caption)
            }
            .foregroundStyle(destructive ? AP.Palette.danger : AP.Palette.paper)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title == "All pages" ? "Use this look for all pages" : title))
    }

    private func deleteCurrent() {
        let list = pages
        guard let index = list.firstIndex(where: { $0.id == selected }) else { return }
        let next = list.indices.contains(index + 1) ? list[index + 1].id : (index > 0 ? list[index - 1].id : nil)
        store.deletePage(docID, selected)
        if let next { selected = next } else { dismiss() }
    }
}

// MARK: - Preview

private struct PagePreview: View {
    @EnvironmentObject private var store: DocStore
    let page: PageRecord

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image)
                    .padding(AP.Space.m)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(page.id.uuidString)-\(page.version)") {
            let storage = store.storage
            let snapshot = page
            let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
                storage.render(snapshot, maxSide: 1800, decodeSide: 2400).map { UIImage(cgImage: $0) }
            }.value
            if let rendered { image = rendered }
        }
    }
}

// MARK: - Look tiles

private struct FilterTile: View {
    @EnvironmentObject private var store: DocStore
    let page: PageRecord
    let filter: ScanFilter
    let selected: Bool
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    AP.Palette.sheet
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                }
                .frame(width: 64, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? AP.Palette.brass : AP.Palette.line, lineWidth: selected ? 2.5 : 1)
                )
                Text(filter.title)
                    .font(AP.Font.caption)
                    .foregroundStyle(selected ? AP.Palette.brass : AP.Palette.mist)
                    .lineLimit(1)
                    .frame(width: 76)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(filter.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: "\(page.id.uuidString)-\(page.quarterTurns)-\(String(describing: page.quad))") {
            let storage = store.storage
            var snapshot = page
            snapshot.filter = filter
            let rendered: UIImage? = await Task.detached(priority: .utility) {
                storage.render(snapshot, maxSide: 200, decodeSide: 500).map { UIImage(cgImage: $0) }
            }.value
            if let rendered { image = rendered }
        }
    }
}

// MARK: - Crop

struct CropView: View {
    let docID: UUID
    let pageID: UUID

    @EnvironmentObject private var store: DocStore
    @Environment(\.dismiss) private var dismiss

    @State private var quad: Quad = .full
    @State private var image: UIImage?
    @State private var note: String?
    @State private var detecting = false

    private let space = "cropSpace"

    var body: some View {
        NavigationStack {
            VStack(spacing: AP.Space.m) {
                GeometryReader { geo in
                    ZStack {
                        if let image {
                            let fit = fitRect(image.size, in: geo.size)
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: fit.width, height: fit.height)
                                .position(x: fit.midX, y: fit.midY)
                            overlay(fit: fit, size: geo.size)
                        } else {
                            ProgressView()
                        }
                    }
                    .coordinateSpace(name: space)
                }
                .padding(.horizontal, AP.Space.m)

                VStack(spacing: AP.Space.s) {
                    if let note { StatusLine(text: note, tone: .neutral) }
                    HStack(spacing: AP.Space.s) {
                        Button { detect() } label: {
                            HStack(spacing: 6) {
                                if detecting { ProgressView() }
                                Label("Find edges", systemImage: "viewfinder")
                            }
                        }
                        .buttonStyle(.apSecondaryWide)
                        .disabled(image == nil || detecting)
                        Button { quad = .full; note = nil } label: { Label("Whole photo", systemImage: "rectangle") }
                            .buttonStyle(.apSecondaryWide)
                    }
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.s)
            }
            .apScreen()
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commit() }
                        .fontWeight(.semibold)
                        .disabled(!quad.isUsable)
                }
            }
            .task { await load() }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Drawing

    private func fitRect(_ imageSize: CGSize, in box: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func point(_ q: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + q.x * fit.width, y: fit.minY + q.y * fit.height)
    }

    private func normalized(_ location: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (location.x - fit.minX) / max(1, fit.width))),
            y: min(1, max(0, (location.y - fit.minY) / max(1, fit.height)))
        )
    }

    private func overlay(fit: CGRect, size: CGSize) -> some View {
        let points = quad.points.map { point($0, in: fit) }
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .stroke(AP.Palette.brass, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .allowsHitTesting(false)

            handle(0, "Top left corner", fit: fit)
            handle(1, "Top right corner", fit: fit)
            handle(2, "Bottom right corner", fit: fit)
            handle(3, "Bottom left corner", fit: fit)
        }
    }

    private func handle(_ index: Int, _ label: String, fit: CGRect) -> some View {
        let p = point(quad.points[index], in: fit)
        return Circle()
            .fill(AP.Palette.brass)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
            .frame(width: 26, height: 26)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .position(p)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        let n = normalized(value.location, in: fit)
                        switch index {
                        case 0: quad.tl = n
                        case 1: quad.tr = n
                        case 2: quad.br = n
                        default: quad.bl = n
                        }
                        note = nil
                    }
            )
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text("Drag to move. Or use Find edges or Whole photo."))
    }

    // MARK: Actions

    private func load() async {
        let storage = store.storage
        let id = pageID
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            storage.loadSource(id, maxPixel: 1600).map { UIImage(cgImage: $0) }
        }.value
        image = loaded
        quad = store.page(docID, pageID)?.quad ?? .full
    }

    private func detect() {
        guard let cg = image?.cgImage else { return }
        detecting = true
        Task {
            let found: Quad? = await Task.detached(priority: .userInitiated) { DocumentDetector.detect(cg) }.value
            detecting = false
            if let found {
                withAnimation(.easeOut(duration: 0.25)) { quad = found }
                note = nil
            } else {
                note = "No page edges found. Drag the corners to the page."
            }
        }
    }

    private func commit() {
        guard quad.isUsable else { return }
        let final: Quad? = quad.isFull ? nil : quad
        store.updatePage(docID, pageID) { $0.quad = final }
        dismiss()
    }
}
