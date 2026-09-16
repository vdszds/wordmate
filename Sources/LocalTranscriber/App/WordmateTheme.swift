import AppKit
import SwiftUI

enum WordmateTheme {
    static let primaryAction = Color(nsColor: .systemBlue)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let control = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let controlBorder = Color(nsColor: .separatorColor)
    static let inactive = Color(nsColor: .quaternaryLabelColor)
    static let shadow = Color(nsColor: .shadowColor)
    static let success = Color(nsColor: .systemGreen)
    static let successFill = success.opacity(0.1)
}

private struct WordmateSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .background(
                WordmateTheme.surface,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .shadow(
                color: shadow ? WordmateTheme.shadow.opacity(0.12) : .clear,
                radius: shadow ? 12 : 0,
                y: shadow ? 4 : 0
            )
    }
}

extension View {
    func wordmateSurface(
        cornerRadius: CGFloat = 16,
        shadow: Bool = false
    ) -> some View {
        modifier(
            WordmateSurfaceModifier(
                cornerRadius: cornerRadius,
                shadow: shadow
            )
        )
    }
}
