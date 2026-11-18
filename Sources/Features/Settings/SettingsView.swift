import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var ads = AdsManager.shared

    @AppStorage(FoliaPrefs.filterKey) private var filterRaw = ScanFilter.auto.rawValue
    @AppStorage(FoliaPrefs.pageSizeKey) private var pageSizeRaw = PageSizeOption.auto.rawValue
    @State private var signature: UIImage? = SignatureStore.load()
    @State private var confirmClear = false

    private let privacyURL = URL(string: "https://ecomswiftllc.github.io/folia/privacy/")!
    private let supportURL = URL(string: "https://ecomswiftllc.github.io/folia/support/")!
    private let reviewURL = URL(string: "https://apps.apple.com/app/id6836099515?action=write-review")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Settings", subtitle: "Folia is free. Your documents never leave your device.")

                    VStack(alignment: .leading, spacing: AP.Space.s) {
                        APSectionTitle(text: "Scanning")
                        VStack(spacing: 0) {
                            APHairline()
                            menuRow("New pages look", symbol: "wand.and.stars", value: ScanFilter(rawValue: filterRaw)?.title ?? "Auto") {
                                Picker("New pages look", selection: $filterRaw) {
                                    ForEach(ScanFilter.allCases) { Text($0.title).tag($0.rawValue) }
                                }
                            }
                            APHairline()
                            menuRow("PDF page size", symbol: "doc", value: PageSizeOption(rawValue: pageSizeRaw)?.title ?? "Fit scan") {
                                Picker("PDF page size", selection: $pageSizeRaw) {
                                    ForEach(PageSizeOption.allCases) { Text($0.title).tag($0.rawValue) }
                                }
                            }
                            APHairline()
                        }
                    }

                    VStack(alignment: .leading, spacing: AP.Space.s) {
                        APSectionTitle(text: "Signature")
                        if let signature {
                            HStack(spacing: AP.Space.m) {
                                Image(uiImage: signature)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 56)
                                    .padding(AP.Space.s)
                                    .background(AP.Palette.sheet, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous).strokeBorder(AP.Palette.line, lineWidth: 1))
                                    .accessibilityLabel(Text("Your saved signature"))
                                Spacer()
                                Button("Remove", role: .destructive) { confirmClear = true }
                                    .font(AP.Font.label)
                            }
                        } else {
                            Text("No signature saved. Draw one in Tools, Sign and fill.")
                                .font(AP.Font.callout)
                                .foregroundStyle(AP.Palette.mist)
                        }
                    }

                    VStack(alignment: .leading, spacing: AP.Space.s) {
                        APSectionTitle(text: "About")
                        VStack(spacing: 0) {
                            APHairline()
                            if ads.privacyOptionsRequired {
                                row("Ad privacy choices", symbol: "hand.raised") { ads.presentPrivacyOptions() }
                                APHairline()
                            }
                            row("Rate Folia", symbol: "star") { openURL(reviewURL) }
                            APHairline()
                            link("Support", symbol: "questionmark.circle", url: supportURL)
                            APHairline()
                            link("Privacy policy", symbol: "lock", url: privacyURL)
                            APHairline()
                            link("Email us", symbol: "envelope", url: URL(string: "mailto:support@ecomswiftllc.com")!)
                            APHairline()
                        }
                    }

                    Text("Folia is free and supported by ads. Saving, sharing or printing asks you to watch one short ad (free if no ad is available). Version \(version)")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.xl)
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Remove your saved signature?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove signature", role: .destructive) {
                    SignatureStore.clear()
                    signature = nil
                }
                Button("Keep it", role: .cancel) {}
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func menuRow<M: View>(_ title: String, symbol: String, value: String, @ViewBuilder menu: () -> M) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: AP.Space.m) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(AP.Palette.brass).frame(width: 28)
                Text(title).font(AP.Font.body).foregroundStyle(AP.Palette.paper)
                Spacer()
                Text(value).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(AP.Palette.mist)
            }
            .padding(.vertical, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, symbol: symbol) }
            .buttonStyle(.plain)
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) { rowLabel(title, symbol: symbol) }
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(AP.Palette.brass).frame(width: 28)
            Text(title).font(AP.Font.body).foregroundStyle(AP.Palette.paper)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(AP.Palette.mist)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: AP.Space.xl)
                    FoliaMark(lineWidth: 2)
                        .frame(width: 92, height: 112)
                        .offset(y: appeared ? 0 : 14)
                        .opacity(appeared ? 1 : 0)
                        .padding(.bottom, AP.Space.l)
                    Text("Paper in,\nPDF out.")
                        .apDisplay(50)
                        .lineSpacing(-2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Scan, sign and tidy documents with nothing to pay and nothing uploaded.")
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AP.Space.m)
                        .frame(maxWidth: 340, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        APHairline()
                        line("camera.viewfinder", "Scan in seconds", "Edges found, light fixed, pages saved as PDF.")
                        APHairline()
                        line("signature", "Sign, merge, compress", "Twelve tools for the PDFs you already have.")
                        APHairline()
                        line("lock", "Private by design", "Documents and text recognition stay on this device.")
                        APHairline()
                    }
                    .padding(.top, AP.Space.xl)
                    Spacer(minLength: AP.Space.l)
                    Text("Free, supported by ads. Saving, sharing or printing asks you to watch one short ad (free if no ad is available).")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, AP.Space.s)
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { appState.hasOnboarded = true }
                    } label: {
                        Text("Get started")
                    }
                    .buttonStyle(.apPrimaryWide)
                    .padding(.bottom, AP.Space.l)
                }
                .padding(.horizontal, AP.Space.l)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .apScreen()
        .onAppear {
            if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 0.9)) { appeared = true } }
        }
    }

    private func line(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
