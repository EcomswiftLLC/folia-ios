import SwiftUI

struct DocumentView: View {
    let docID: UUID

    @EnvironmentObject private var store: DocStore
    @EnvironmentObject private var importer: ImportController
    @Environment(.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss

    @State private var showExport = false
    @State private var showReorder = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var route: ToolRoute?

    private var doc: DocRecord? { store.doc(docID) }

    var body: some View {
        Group {
            if let doc {
                content(doc)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    private func content(_ doc: DocRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AP.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.title).apDisplay(30).lineLimit(2)
                    Text("\(FoliaText.pages(doc.pages.count)). Tap a page to crop, filter or rotate it.")
                        .font(AP.Font.callout)
                        .foregroundStyle(AP.Palette.mist)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: hSize == .regular ? 210 : 150), spacing: AP.Space.m)], spacing: AP.Space.l) {
                    ForEach(Array(doc.pages.enumerated()), id: \.element.id) { index, page in
                        NavigationLink(value: PageRoute(docID: docID, pageID: page.id)) {
                            PageCell(page: page, number: index + 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { store.rotate(docID, page.id, by: -1) } label: { Label("Rotate left", systemImage: "rotate.left") }
                            Button { store.rotate(docID, page.id, by: 1) } label: { Label("Rotate right", systemImage: "rotate.right") }
                            Button(role: .destructive) { store.deletePage(docID, page.id) } label: { Label("Delete page", systemImage: "trash") }
                        }
                    }
                }
            }
            .padding(.horizontal, AP.Space.m)
            .padding(.bottom, AP.Space.l)
        }
        .apScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(doc) }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationDestination(item: $route) { $0.destination }
        .sheet(isPresented: $showExport) { ExportSheet(docID: docID) }
        .sheet(isPresented: $showReorder) { ReorderSheet(docID: docID) }
        .alert("Rename document", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { store.rename(docID, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this document?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete document", role: .destructive) {
                store.deleteDoc(docID)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The document and its pages are removed from this device. This can’t be undone.")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ doc: DocRecord) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button { route = .text(docID) } label: { Label("Extract text", systemImage: "text.viewfinder") }
                    Button { route = .sign(docID) } label: { Label("Sign and fill", systemImage: "signature") }
                    Button { route = .numbers(docID) } label: { Label("Add page numbers", systemImage: "number") }
                    Button { route = .watermark(docID) } label: { Label("Add watermark", systemImage: "drop") }
                    Button { route = .protect(docID) } label: { Label("Protect with password", systemImage: "lock") }
                }
                Section {
                    Menu {
                        ForEach(ScanFilter.allCases) { filter in
                            Button { store.setFilterForAll(docID, filter) } label: { Label(filter.title, systemImage: filter.symbol) }
                        }
                    } label: {
                        Label("Look for all pages", systemImage: "wand.and.stars")
                    }
                    Button { showReorder = true } label: { Label("Reorder pages", systemImage: "arrow.up.arrow.down") }
                    Button {
                        renameText = doc.title
                        showRename = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button { store.duplicate(docID) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete document", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("More actions"))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: AP.Space.s) {
            AddPagesMenu(into: docID) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AP.Palette.paper)
                    .frame(width: 48, height: 48)
                    .background(AP.Palette.carbon, in: Circle())
                    .overlay(Circle().strokeBorder(AP.Palette.line, lineWidth: 1))
            }
            .accessibilityLabel(Text("Add pages"))
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.apPrimaryWide)
        }
        .padding(.horizontal, AP.Space.m)
        .padding(.vertical, AP.Space.s)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Page cell

struct PageCell: View {
    let page: PageRecord
    let number: Int

    var body: some View {
        VStack(spacing: 6) {
            PageThumbnail(page: page, pixels: 520)
                .aspectRatio(0.74, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
            Text("\(number)")
                .font(AP.Font.number)
                .foregroundStyle(AP.Palette.mist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \(number)"))
        .accessibilityHint(Text("Opens the page editor"))
    }
}

// MARK: - Reorder

struct ReorderSheet: View {
    let docID: UUID

    @EnvironmentObject private var store: DocStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array((store.doc(docID)?.pages ?? []).enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: AP.Space.m) {
                        PageThumbnail(page: page, pixels: 160)
                            .frame(width: 44, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                        Text("Page \(index + 1)").font(AP.Font.body).foregroundStyle(AP.Palette.paper)
                    }
                    .listRowBackground(AP.Palette.carbon)
                }
                .onMove { store.movePages(docID, from: $0, to: $1) }
                .onDelete { offsets in
                    let pages = store.doc(docID)?.pages ?? []
                    for offset in offsets where offset < pages.count { store.deletePage(docID, pages[offset].id) }
                }
            }
            .scrollContentBackground(.hidden)
            .apScreen()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
