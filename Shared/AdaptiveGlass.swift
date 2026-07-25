import SwiftUI

/// Liquid Glass on OS 26+, a `.regularMaterial` fallback below. A `ViewModifier`
/// can't itself be `@available`-gated, so the branch lives inside `body`; the
/// imperative glass construction lives in a (non-ViewBuilder) computed property.
struct AdaptiveGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.10), lineWidth: 1))
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Applies Liquid Glass (macOS 26 / iOS 26) or a material fallback.
    func adaptiveGlass(in shape: some Shape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(AdaptiveGlass(shape: shape, tint: tint, interactive: interactive))
    }
}
