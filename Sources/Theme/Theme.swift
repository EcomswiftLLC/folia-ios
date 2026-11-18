import SwiftUI
import UIKit

/// Folia design tokens. The app follows the system appearance. Light is a cool, slightly blue-grey "vellum" with a
/// deep green accent (the colour of a ledger spine); dark is graphite with a mint accent. Token names are kept
/// from the shared app kit: `lens` = background, `carbon` = surface, `graphite` = raised surface, `paper` = primary
/// text, `mist` = secondary text, `brass` = accent.
enum AP {
    enum Palette {
        static let lens      = dynamic(light: 0xF1F3F5, dark: 0x0D1013)
        static let carbon    = dynamic(light: 0xFFFFFF, dark: 0x161A1F)
        static let graphite  = dynamic(light: 0xE6E9ED, dark: 0x21262C)
        static let line      = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.10) })
        static let paper     = dynamic(light: 0x0F1419, dark: 0xECEFF2)
        /// Secondary text: 5.9:1 on `lens` in light, 7:1 in dark.
        static let mist      = dynamic(light: 0x56606B, dark: 0x9FA7B0)
        static let brass     = dynamic(light: 0x0B7A62, dark: 0x4FD1AC)
        static let brassDeep = dynamic(light: 0x075C4A, dark: 0x2FA987)
        static let onBrass   = dynamic(light: 0xFFFFFF, dark: 0x06241B)
        static let danger    = dynamic(light: 0xB3261E, dark: 0xF2A199)
        static let success   = dynamic(light: 0x1B7F4A, dark: 0x7FD4A3)
        /// Page-shaped surfaces (thumbnails, previews) are always white, like paper.
        static let sheet     = Color.white

        static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let panel: CGFloat = 20
    }

    enum Font {
        static func display(_ size: CGFloat = 38) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .serif)
        }
        static func title(_ size: CGFloat = 24) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .serif)
        }
        static let headline = SwiftUI.Font.system(.headline, design: .default).weight(.semibold)
        static let body = SwiftUI.Font.system(.body, design: .default)
        static let callout = SwiftUI.Font.system(.callout, design: .default)
        static let label = SwiftUI.Font.system(.footnote, design: .default).weight(.medium)
        static let caption = SwiftUI.Font.system(.caption, design: .default)
        static let number = SwiftUI.Font.system(.callout, design: .rounded).monospacedDigit().weight(.medium)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// Full-screen background in the app's base colour.
    func apScreen() -> some View {
        background(AP.Palette.lens.ignoresSafeArea())
    }

    /// Editorial headline treatment. The size follows Dynamic Type, relative to Large Title.
    func apDisplay(_ size: CGFloat = 38) -> some View {
        modifier(APScaledSerif(size: size, weight: .regular, relativeTo: .largeTitle))
            .tracking(-0.6)
            .foregroundStyle(AP.Palette.paper)
    }

    /// Serif title treatment that follows Dynamic Type, relative to Title 2.
    func apTitle(_ size: CGFloat = 24) -> some View {
        modifier(APScaledSerif(size: size, weight: .medium, relativeTo: .title2))
    }
}

/// A fixed-design serif whose point size scales with the person's text size setting.
struct APScaledSerif: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: SwiftUI.Font.Weight

    init(size: CGFloat, weight: SwiftUI.Font.Weight, relativeTo style: SwiftUI.Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .serif))
    }
}

/// Appearance for system bars, set once at launch.
enum APAppearance {
    static func configure() {
        let text = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xECEFF2) : UIColor(hex: 0x0F1419) }
        let accent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x4FD1AC) : UIColor(hex: 0x0B7A62) }
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.titleTextAttributes = [.foregroundColor: text]
        nav.largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = accent
    }
}
