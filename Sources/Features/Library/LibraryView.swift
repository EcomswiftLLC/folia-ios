import SwiftUI

struct PageRoute: Hashable {
    let docID: UUID
    let pageID: UUID
}

/// Tools that can start from a document in the library.
enum ToolRoute: Hashable {
    case sign(UUID)
    case numbers(UUID)
    case watermark(UUID)
    case protect(UUID)
    case text(UUID)

    @ViewBuilder
    var destination: some View {
        switch self {
        case .sign(let id): SignTool(initialDoc: id)
        case .numbers(let id): NumbersTool(initialDoc: id)
        case .watermark(let id): WatermarkTool(initialDoc: id)
        case .protect(let id): LockTool(initialDoc: id)
        case .text(let id): TextResultView(docID: id)
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .name: return "Name"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: DocStore
    @EnvironmentObject private var importer: ImportController
    @AppStorage(FoliaPrefs.sortKey) private var sortRaw = LibrarySort.newest.rawValue

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showSettings = false
    @State private var renaming: DocRecord?
    @State private var renameText = ""
    @State private var deleting: DocRecord?

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    private var visible: [DocRecord] {
        let matching = store.docs.filter { DocStore.matches($0, query: query) }
        switch sort {
        case .newest: return matching.sorted { $0.modifiedAt > $1.modifiedAt }
        case .oldest: return matching.sorted { $0.modifiedAt < $1.modifiedAt }
        case .name: return matching.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Documents", subtitle: subtitle)
                    if store.docs.isEmpty {
                        emptyLibrary
                    } else if visible.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Nothing in your documents matches “\(query)”. Search covers titles and the text found on each page.")
                            .frame(maxWidth: .infinity)
                    } else {
                        grid
                        // Only under real content, never on the empty or "No matches" screens, and kept clear of
                        // the Scan bar below.
                        CKInlineBanner()
                            .padding(.top, AP.Space.s)
                            .padding(.bottom, AP.Space.l)
                    }
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.l)
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search titles and text")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationDestination(for: UUID.self) { DocumentView(docID: $0) }
            .navigationDestination(for: PageRoute.self) { PageEditorView(docID: $0.docID, startPage: $0.pageID) }
            .navigationDestination(for: ToolRoute.self) { $0.destination }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: importer.openDoc) { _, id in
            guard let id else { return }
            path.append(id)
            importer.openDoc = nil
        }
        .alert("Rename document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { store.rename(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete document", role: .destructive) {
                if let deleting { store.deleteDoc(deleting.id) }
                deleting = nil
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: {
            Text("The document and its pages are removed from this device. This can’t be undone.")
        }
    }

    private var subtitle: String {
        if store.docs.isEmpty { return "Scan paper, import photos or open a PDF." }
        let docs = store.docs.count == 1 ? "1 document" : "\(store.docs.count) documents"
        return "\(docs), \(FoliaText.pages(store.totalPages)). Stored on this device only."
    }

    // MARK: Parts

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AP.Space.m)], spacing: AP.Space.l) {
            ForEach(visible) { doc in
                NavigationLink(value: doc.id) { DocCard(doc: doc) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameText = doc.title
                            renaming = doc
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button { store.duplicate(doc.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { deleting = doc } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: AP.Space.l) {
            EmptyStateView(
                symbol: "doc.viewfinder",
                title: "Your first scan starts here",
                message: "Point the camera at a page, or bring in photos and PDFs you already have."
            )
            VStack(spacing: AP.Space.s) {
                Button { importer.scan() } label: { Label("Scan a document", systemImage: "camera.viewfinder") }
                    .buttonStyle(.apPrimaryWide)
                HStack(spacing: AP.Space.s) {
                    Button { importer.choosePhotos() } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.apSecondaryWide)
                    Button { importer.chooseFiles() } label: { Label("Files", systemImage: "folder") }
                        .buttonStyle(.apSecondaryWide)
                }
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AP.Space.xl)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(Text("Settings"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel(Text("Sort documents"))
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if !store.docs.isEmpty {
            HStack(spacing: AP.Space.s) {
                Button { importer.scan() } label: { Label("Scan", systemImage: "camera.viewfinder") }
                    .buttonStyle(.apPrimary)
                AddPagesMenu(into: nil) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AP.Palette.paper)
                        .frame(width: 48, height: 48)
                        .background(AP.Palette.carbon, in: Circle())
                        .overlay(Circle().strokeBorder(AP.Palette.line, lineWidth: 1))
                }
                .accessibilityLabel(Text("Add from Photos or Files"))
            }
            .padding(.vertical, AP.Space.s)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Card

struct DocCard: View {
    let doc: DocRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let first = doc.pages.first {
                    PageThumbnail(page: first, pixels: 520)
                } else {
                    AP.Palette.sheet
                }
                if doc.pages.count > 1 {
                    Label("\(doc.pages.count)", systemImage: "square.on.square")
                        .font(AP.Font.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(8)
                }
            }
            .aspectRatio(0.74, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.paper)
                    .lineLimit(2)
                Text("\(FoliaText.pages(doc.pages.count)) · \(FoliaText.date(doc.modifiedAt))")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
