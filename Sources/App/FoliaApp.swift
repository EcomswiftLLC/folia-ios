import SwiftUI

@main
struct FoliaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var ads = AdsManager.shared
    @StateObject private var store = DocStore()
    @StateObject private var importer = ImportController()

    init() {
        APAppearance.configure()
        // Shared copies are only needed while a share sheet is open.
        ExportFile.cleanTemporary()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(ads)
                .environmentObject(store)
                .environmentObject(importer)
                .tint(AP.Palette.brass)
        }
    }
}

final class AppState: ObservableObject {
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "folia.hasOnboarded") }
    }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: "folia.hasOnboarded")
    }
}

/// Chooses between the welcome screen and the app, and starts ads only after the first frame
/// and only once the person is past the welcome screen. Launch is never blocked by ads.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var ads: AdsManager
    @State private var adsStarted = false

    var body: some View {
        ZStack {
            #if DEBUG
            if let screen = DebugScreens.requested {
                DebugScreens.view(for: screen)
            } else {
                content
            }
            #else
            content
            #endif
        }
        .apScreen()
        .task(id: appState.hasOnboarded) { await startAdsWhenReady() }
        .onChange(of: ads.adsReady) { _, ready in
            if ready { RewardedGate.shared.preloadIfPossible() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.hasOnboarded {
            MainTabs().transition(.opacity)
        } else {
            OnboardingView().transition(.opacity)
        }
    }

    private func startAdsWhenReady() async {
        #if DEBUG
        if DebugScreens.requested != nil { return }
        #endif
        guard appState.hasOnboarded, !adsStarted else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, !adsStarted else { return }
        adsStarted = true
        await ads.start()
    }
}

/// The two main areas: the library of scans, and the tools that work on any PDF.
struct MainTabs: View {
    enum Tab { case documents, tools }

    @EnvironmentObject private var importer: ImportController
    @State private var tab: Tab

    init(start: Tab = .documents) {
        _tab = State(initialValue: start)
    }

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Documents", systemImage: "doc.on.doc") }
                .tag(Tab.documents)
            ToolsView()
                .tabItem { Label("Tools", systemImage: "square.grid.2x2") }
                .tag(Tab.tools)
        }
        .importSheets(importer)
        .onChange(of: importer.openDoc) { _, id in
            if id != nil { tab = .documents }
        }
    }
}
