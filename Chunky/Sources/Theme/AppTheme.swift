import SwiftUI

/// Adaptive color system that works in both light and dark modes
/// Follows Apple's design guidelines for macOS applications
enum AppTheme {
    // MARK: - Accent Colors

    /// Primary accent - a subtle teal that works in both modes
    static let accent = Color("AccentColor", bundle: nil)

    /// Fallback accent when asset not available
    static var accentFallback: Color {
        Color(light: Color(hue: 0.52, saturation: 0.45, brightness: 0.65),
              dark: Color(hue: 0.52, saturation: 0.35, brightness: 0.80))
    }

    // MARK: - Status Colors

    static var statusGreen: Color {
        Color(light: Color(hue: 0.35, saturation: 0.65, brightness: 0.55),
              dark: Color(hue: 0.35, saturation: 0.50, brightness: 0.70))
    }

    static var statusRed: Color {
        Color(light: Color(hue: 0.0, saturation: 0.65, brightness: 0.65),
              dark: Color(hue: 0.0, saturation: 0.50, brightness: 0.75))
    }

    static var statusOrange: Color {
        Color(light: Color(hue: 0.08, saturation: 0.70, brightness: 0.70),
              dark: Color(hue: 0.08, saturation: 0.55, brightness: 0.80))
    }

    // MARK: - Surface Colors

    /// Elevated surface background (cards, panels)
    static var surfaceElevated: Color {
        Color(light: .white,
              dark: Color(white: 0.15))
    }

    /// Subtle background for grouped content
    static var surfaceGrouped: Color {
        Color(light: Color(white: 0.97),
              dark: Color(white: 0.10))
    }

    /// Glass-like overlay background
    static var surfaceGlass: Color {
        Color(light: Color.white.opacity(0.70),
              dark: Color.white.opacity(0.08))
    }

    // MARK: - Badge/Tag Colors

    static var badgeBackground: Color {
        Color(light: Color.primary.opacity(0.08),
              dark: Color.primary.opacity(0.12))
    }

    static var badgeBackgroundActive: Color {
        Color(light: accentFallback.opacity(0.15),
              dark: accentFallback.opacity(0.25))
    }

    // MARK: - Border Colors

    static var borderSubtle: Color {
        Color(light: Color.primary.opacity(0.08),
              dark: Color.primary.opacity(0.15))
    }

    static var borderMedium: Color {
        Color(light: Color.primary.opacity(0.15),
              dark: Color.primary.opacity(0.25))
    }
}

// MARK: - Color Extension for Light/Dark Variants

extension Color {
    /// Creates a color that adapts to light/dark mode
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return NSColor(dark)
            default:
                return NSColor(light)
            }
        })
    }
}

// MARK: - View Modifiers for Glass Effects

extension View {
    /// Applies a glass-like material background (fallback for pre-Liquid Glass)
    func glassBackground(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Applies a subtle card-like background
    func cardBackground(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    /// Applies an interactive glass effect for buttons/controls
    func interactiveGlass(cornerRadius: CGFloat = 8) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Status Indicator View

struct StatusDot: View {
    let isActive: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isActive ? AppTheme.statusGreen : AppTheme.statusRed)
            .frame(width: size, height: size)
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
}

// MARK: - Tinted Button Style

struct TintedButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(configuration.isPressed ? 0.9 : 1.0), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
