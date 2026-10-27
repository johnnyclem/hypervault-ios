import SwiftUI

/// Code and commands, in the web's code panel: content, never chrome, so it is the same under any look (style guide
/// 2.3). Fixed colours (`#14161b`, with `#e6e8ec` text and a white 6% edge), 16pt corners, the caption size in
/// monospace and no material. The text wraps instead of scrolling sideways, and can be selected to copy.
struct HVCodePanel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous)
        Text(text)
            .font(.hvCode)
            .foregroundStyle(HVColor.docPanelForeground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HV.Space.s)
            .background(HVColor.docPanelBackground, in: shape)
            .overlay(shape.strokeBorder(HVColor.docPanelBorder, lineWidth: 1))
    }
}

#Preview("Code panel") {
    HVCodePanel("curl -H \"Authorization: Bearer $HV_KEY\" https://hypervault.store/api/secrets/stripe-key")
        .padding(HV.Space.m)
        .hvScreenBackground()
}
