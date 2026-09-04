import SwiftUI

enum TyperTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.041)
    static let chrome = Color(red: 0.055, green: 0.055, blue: 0.064)
    static let surface = Color(red: 0.073, green: 0.073, blue: 0.090)
    static let raised = Color(red: 0.105, green: 0.102, blue: 0.132)
    static let hover = Color(red: 0.145, green: 0.140, blue: 0.180)
    static let ink = Color(red: 0.946, green: 0.944, blue: 0.972)
    static let muted = Color(red: 0.560, green: 0.555, blue: 0.640)
    static let mutedStrong = Color(red: 0.710, green: 0.705, blue: 0.785)
    static let primary = Color(red: 0.335, green: 0.365, blue: 0.960)
    static let primaryStrong = Color(red: 0.270, green: 0.290, blue: 0.825)
    static let signal = Color(red: 0.670, green: 0.930, blue: 0.240)
    static let danger = Color(red: 0.950, green: 0.360, blue: 0.300)
    static let line = Color.white.opacity(0.12)
    static let softLine = Color.white.opacity(0.075)
}

struct SurfaceModifier: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(TyperTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func typerSurface(radius: CGFloat = 12) -> some View { modifier(SurfaceModifier(radius: radius)) }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? TyperTheme.ink : TyperTheme.mutedStrong)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? TyperTheme.hover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(configuration.isPressed ? TyperTheme.primaryStrong : TyperTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TyperTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(configuration.isPressed ? TyperTheme.hover : TyperTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }
}
