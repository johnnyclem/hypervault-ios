import SwiftUI

/// A choice between a few options. A segmented control stays at its small size however large the text is set,
/// so at the largest sizes the choice becomes a menu whose words grow with the rest of the screen.
struct FeatureChoicePicker<Selection: Hashable, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var content: () -> Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.menu)
                .frame(minHeight: 44)
        } else {
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.segmented)
        }
    }
}
