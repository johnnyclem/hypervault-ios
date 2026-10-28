import SwiftUI

extension View {
    /// The bar pinned under a screen that scrolls: a filled button and, when there is one, the sentence that says what it
    /// is for. It is the content of a `safeAreaInset(edge: .bottom, spacing: 0)`, which also keeps the end of what scrolls
    /// clear of the bar.
    ///
    /// It is the page's own colour, solid, with a short fade above it, and it is not glass. Rows that scroll under glass
    /// show through it as smeared ghost text beneath the words and the button, and a glass pill around a button has two
    /// corner radii and two borders. Here the button is the one shape on the bar. Glass stays for the composer, the legend
    /// and the bars that hold no text of the page's.
    func hvActionBar() -> some View {
        modifier(HVActionBarModifier())
    }
}

private struct HVActionBarModifier: ViewModifier {
    /// How far above the bar the page's colour fades in, so what scrolls under it is not cut off by a line.
    private let fade = HV.Space.m

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .hvReadableWidth()
            .background(alignment: .bottom) { scrim }
    }

    private var scrim: some View {
        ZStack(alignment: .top) {
            Palette.background
            LinearGradient(
                colors: [Palette.background.opacity(0), Palette.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fade)
            .offset(y: -fade)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
