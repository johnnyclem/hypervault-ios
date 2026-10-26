import SwiftUI

// STUB: the real sheet arrives with the Keep share extension.
struct ShareView: View {
    let context: NSExtensionContext?

    var body: some View {
        VStack(spacing: HV.Space.m) {
            BrandMark(size: 56)
            Text("Keep in HyperVault").font(.hvTitle)
            Button("Done") { context?.completeRequest(returningItems: nil) }
                .buttonStyle(.hvPrimary)
        }
        .padding(HV.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
