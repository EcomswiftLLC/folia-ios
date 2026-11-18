#if DEBUG
import SwiftUI
import UIKit

/// Debug builds can open a given screen directly, with sample documents, so CI can take screenshots of every screen without
/// tapping through the app: `xcrun simctl launch <device> com.ecomswift.folia -foScreen library`.
/// Sample pages are photographs of generated documents that CI copies into the simulator app's Documents/samples folder
/// together with a manifest.json that lists the documents and the page corners found in each photo.
enum DebugScreens {
    /// `-foLandscape YES` turns an iPad simulator to landscape so CI can check wide layouts.
    static func landscapeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "foLandscape") else { return }
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                    try? "\(error)".write(toFile: "/tmp/foLandscape-error.txt", atomically: true, encoding: .utf8)
                }
                // Older route that the simulator still honours.
                UIDevice.current.setValue(UIInterfaceOrientation.landscapeLeft.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }


    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "foScreen"), !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    static func view(for screen: String) -> some View {
        DebugHost(screen: screen)
    }
}

private struct Manifest: Decodable {
    struct Page: Decodable {
        var file: String
        var quad: [[Double]]?
        var filter: String?
    }

    struct Doc: Decodable {
        var title: String
        var pages: [Page]
    }

    var docs: [Doc]
}

struct DebugHost: View {
    let screen: String

    @StateObject private var store = DocStore(
        storage: PageStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("folia-debug-\(UUID().uuidString)", isDirectory: true))
    )
    @StateObject private var importer = ImportController()
    @StateObject private var appState = AppState()
    @State private var ready = false
    @State private var seeded: [UUID] = []

    var body: some View {
        Group {
            if ready { content } else { ProgressView() }
        }
        .environmentObject(store)
        .environmentObject(importer)
        .environmentObject(appState)
        .tint(AP.Palette.brass)
        .task { await seed() }
    }

    private func id(_ index: Int) -> UUID {
        seeded.indices.contains(index) ? seeded[index] : (seeded.first ?? UUID())
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "onboarding": OnboardingView()
        case "settings": SettingsView()
        case "library-empty", "library": MainTabs(start: .documents).importSheets(importer)
        case "tools": MainTabs(start: .tools).importSheets(importer)
        case "doc": NavigationStack { DocumentView(docID: id(2)) }
        case "page": NavigationStack { PageEditorView(docID: id(0), startPage: store.doc(id(0))?.pages.first?.id ?? UUID()) }
        case "page-bw": NavigationStack { PageEditorView(docID: id(1), startPage: store.doc(id(1))?.pages.first?.id ?? UUID()) }
        case "crop": CropView(docID: id(0), pageID: store.doc(id(0))?.pages.first?.id ?? UUID())
        case "export": ExportSheet(docID: id(2))
        case "sign": NavigationStack { SignTool(initialDoc: id(0), demoMarks: true) }
        case "text": NavigationStack { TextResultView(docID: id(1)) }
        case "split": NavigationStack { SplitTool(initialDoc: id(2)) }
        case "compress": NavigationStack { CompressTool(initialDoc: id(2)) }
        default: MainTabs(start: .documents).importSheets(importer)
        }
    }

    private func seed() async {
        if screen == "onboarding" || screen == "library-empty" || screen == "settings" {
            ready = true
            return
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("samples", isDirectory: true)
        var ids: [UUID] = []
        if let folder,
           let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            for doc in manifest.docs {
                var sources: [ScanImporter.Source] = []
                var filters: [ScanFilter] = []
                for page in doc.pages {
                    guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(page.file)),
                          let image = PhotoLoader.decode(bytes, maxPixel: 2600),
                          var source = ScanImporter.makeSource(image, detect: false) else { continue }
                    if let q = page.quad, q.count == 4, q.allSatisfy({ $0.count == 2 }) {
                        source.quad = Quad(
                            tl: CGPoint(x: q[0][0], y: q[0][1]), tr: CGPoint(x: q[1][0], y: q[1][1]),
                            br: CGPoint(x: q[2][0], y: q[2][1]), bl: CGPoint(x: q[3][0], y: q[3][1])
                        )
                    }
                    sources.append(source)
                    filters.append(ScanFilter(rawValue: page.filter ?? "") ?? .auto)
                }
                if let id = store.insert(sources, title: doc.title, filter: filters.first ?? .auto) {
                    ids.append(id)
                    if let record = store.doc(id) {
                        for (index, page) in record.pages.enumerated() where filters.indices.contains(index) {
                            store.updatePage(id, page.id) { $0.filter = filters[index] }
                        }
                    }
                }
            }
        } else {
            for index in 0..<3 {
                let pages = (0...index).compactMap { page in
                    ScanImporter.makeSource(SyntheticPage.make(title: "Sample document \(index + 1)", page: page + 1), detect: false)
                }
                if let id = store.insert(pages, title: "Sample document \(index + 1)") { ids.append(id) }
            }
        }
        seeded = ids
        // Text recognition is slow on a CI simulator, so only the screen that shows recognised text waits for it.
        if screen == "text", ids.indices.contains(1) { await store.recognizeText(docID: ids[1]) }
        ready = true
        for id in ids where !(screen == "text" && id == ids[safe: 1]) { await store.recognizeText(docID: id) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A plain generated page, used only when no sample photographs are installed.
enum SyntheticPage {
    static func make(title: String, page: Int) -> CGImage {
        let size = CGSize(width: 1240, height: 1754)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (title as NSString).draw(at: CGPoint(x: 100, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.black])
            for line in 0..<18 {
                ("Line \(line + 1) of page \(page). The quick brown fox jumps over the lazy dog." as NSString)
                    .draw(at: CGPoint(x: 100, y: 300 + CGFloat(line) * 70), withAttributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.darkGray])
            }
        }
        return image.cgImage!
    }
}
#endif
