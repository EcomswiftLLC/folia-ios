import SwiftUI
import UIKit

// MARK: - Buttons

enum APButtonKind { case primary, secondary, quiet }

struct APButtonStyle: ButtonStyle {
    var kind: APButtonKind = .primary
    var fullWidth: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AP.Font.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, AP.Space.l)
            .padding(.vertical, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .background(background(pressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                    .strokeBorder(kind == .secondary ? AP.Palette.paper.opacity(0.30) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return AP.Palette.onBrass
        case .secondary: return AP.Palette.paper
        case .quiet: return AP.Palette.brass
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch kind {
        case .primary:
            LinearGradient(
                colors: [AP.Palette.brass, AP.Palette.brassDeep.opacity(pressed ? 1 : 0.92)],
                startPoint: .top, endPoint: .bottom
            )
        case .secondary:
            if pressed { AP.Palette.graphite } else { Color.clear }
        case .quiet:
            Color.clear
        }
    }
}

extension ButtonStyle where Self == APButtonStyle {
    static var apPrimary: APButtonStyle { APButtonStyle(kind: .primary) }
    static var apPrimaryWide: APButtonStyle { APButtonStyle(kind: .primary, fullWidth: true) }
    static var apSecondary: APButtonStyle { APButtonStyle(kind: .secondary) }
    static var apSecondaryWide: APButtonStyle { APButtonStyle(kind: .secondary, fullWidth: true) }
    static var apQuiet: APButtonStyle { APButtonStyle(kind: .quiet) }
}

// MARK: - Structure

struct APHairline: View {
    var body: some View {
        Rectangle().fill(AP.Palette.line).frame(height: 1 / UIScreen.main.scale)
    }
}

/// Sentence-case section title in the editorial serif.
struct APSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .apTitle(22)
            .foregroundStyle(AP.Palette.paper)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Small pill used for options (ratio, format, preset).
struct APChip: View {
    let title: String
    var systemImage: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(AP.Font.label).lineLimit(1)
            }
            .foregroundStyle(selected ? AP.Palette.onBrass : AP.Palette.paper)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(selected ? AP.Palette.brass : AP.Palette.graphite, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : AP.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A group of chips that scrolls sideways.
struct APChipRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AP.Space.s) { content() }
                .padding(.horizontal, AP.Space.m)
        }
    }
}

// MARK: - Haptics

enum APHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Folia mark

/// The Folia mark: a sheet with a folded corner, drawn in code so it stays sharp at any size.
struct FoliaMark: View {
    var color: Color = AP.Palette.brass
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let fold = min(w, h) * 0.30
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w * 0.12, y: h * 0.04))
                    p.addLine(to: CGPoint(x: w * 0.88 - fold, y: h * 0.04))
                    p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.04 + fold))
                    p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.96))
                    p.addLine(to: CGPoint(x: w * 0.12, y: h * 0.96))
                    p.closeSubpath()
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                Path { p in
                    p.move(to: CGPoint(x: w * 0.88 - fold, y: h * 0.04))
                    p.addLine(to: CGPoint(x: w * 0.88 - fold, y: h * 0.04 + fold))
                    p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.04 + fold))
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                ForEach(0..<3, id: \.self) { i in
                    Path { p in
                        let y = h * (0.52 + CGFloat(i) * 0.13)
                        p.move(to: CGPoint(x: w * 0.28, y: y))
                        p.addLine(to: CGPoint(x: w * (i == 2 ? 0.55 : 0.72), y: y))
                    }
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .aspectRatio(0.82, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
