import SwiftUI

/// Signing out, in the General pane and in the Account menu. It asks first when something shared from this phone is
/// still waiting to be kept, because signing out discards it.
struct SignOutButton: View {
    var identifier = "you.signOut"
    /// A line under the button's name, for a row that has room for one.
    var detail: String?

    @Environment(AppModel.self) private var model
    @State private var waiting = 0
    @State private var confirmSignOut = false

    var body: some View {
        Button(role: .destructive) {
            // Signing out clears what is still waiting to be kept, so say so first rather than lose it quietly.
            waiting = OutboxStore.count
            if waiting > 0 {
                confirmSignOut = true
            } else {
                Task { await model.signOut() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(Palette.danger)
                if let detail {
                    Text(detail)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out and discard", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text(waiting == 1
                ? "One thing you shared is still waiting to be kept. Signing out discards it."
                : "\(waiting) things you shared are still waiting to be kept. Signing out discards them.")
        }
    }
}
