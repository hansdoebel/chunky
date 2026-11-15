import SwiftUI

enum AppTheme {

    static var accentFallback: Color {
        Color(
            light: Color(hue: 0.52, saturation: 0.45, brightness: 0.65),
            dark: Color(hue: 0.52, saturation: 0.35, brightness: 0.80))
    }

    static var statusGreen: Color {
        Color(
            light: Color(hue: 0.35, saturation: 0.65, brightness: 0.55),
            dark: Color(hue: 0.35, saturation: 0.50, brightness: 0.70))
    }

    static var statusRed: Color {
        Color(
            light: Color(hue: 0.0, saturation: 0.65, brightness: 0.65),
            dark: Color(hue: 0.0, saturation: 0.50, brightness: 0.75))
    }

    static var statusOrange: Color {
        Color(
            light: Color(hue: 0.08, saturation: 0.70, brightness: 0.70),
            dark: Color(hue: 0.08, saturation: 0.55, brightness: 0.80))
    }

    static var surfaceElevated: Color {
        Color(
            light: .white,
            dark: Color(white: 0.15))
    }

    static var surfaceGrouped: Color {
        Color(
            light: Color(white: 0.97),
            dark: Color(white: 0.10))
    }

    static var badgeBackground: Color {
        Color(
            light: Color.primary.opacity(0.08),
            dark: Color.primary.opacity(0.12))
    }

    static var badgeBackgroundActive: Color {
        Color(
            light: accentFallback.opacity(0.15),
            dark: accentFallback.opacity(0.25))
    }

    static var borderSubtle: Color {
        Color(
            light: Color.primary.opacity(0.08),
            dark: Color.primary.opacity(0.15))
    }

}

extension Color {

    init(light: Color, dark: Color) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
                case .darkAqua:
                    return NSColor(dark)
                default:
                    return NSColor(light)
                }
            })
    }
}

struct StatusDot: View {
    let isActive: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isActive ? AppTheme.statusGreen : AppTheme.statusRed)
            .frame(width: size, height: size)
    }
}
