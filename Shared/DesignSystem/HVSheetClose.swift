import SwiftUI

extension View {
    /// A visible Close for a sheet (handoff 4.4 and 9): an xmark button labelled "Close" on the leading side of the
    /// navigation bar. Put it on the root view inside the sheet's `NavigationStack`, as a `.toolbar` goes.
    ///
    /// Pass `isDirty` while the sheet holds something typed that Close would drop. Then a swipe cannot dismiss the sheet
    /// (`interactiveDismissDisabled`), and Close asks first, because the web drops typed values on close without a word
    /// and the phone should not.
    ///
    /// A sheet that already has its own way out (a Cancel, a Done, a Close) does not need this one as well.
    func hvSheetClose(isDirty: Bool = false) -> some View {
        modifier(HVSheetCloseModifier(isDirty: isDirty))
    }
}

struct HVSheetCloseModifier: ViewModifier {
    let isDirty: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if isDirty { asking = true } else { dismiss() }
                    } label: {
                        Label("Close", systemImage: HVSymbol.close)
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard your changes?", isPresented: $asking, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
    }
}

#Preview("Sheet close") {
    NavigationStack {
        Text("A sheet with something typed in it")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hvScreenBackground()
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .hvSheetClose(isDirty: true)
    }
}
