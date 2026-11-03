import SwiftUI

extension View {
    /// Lets code empty or replace the text of a field that has the keyboard, and have the field show it.
    ///
    /// A focused `TextField` can ignore a programmatic write to its string: the model says "" while the field keeps the
    /// old words on screen, and the next keystroke writes them back (Apple has acknowledged a case of it:
    /// developer.apple.com/forums/thread/776161). A view with a new identity starts from the string it is given, so each
    /// reset gives the field one. Bump `epoch` whenever code replaces the text (a message was sent, a stopped one was put
    /// back) and never while the person types: a new identity ends the editing session.
    ///
    /// The old field takes the keyboard with it. If it had the keyboard, the new one is asked for it, unless SwiftUI
    /// has already handed it over. Apply this directly after `.focused(...)`, and keep anything that must survive a reset
    /// (an `onChange` on the text, say) after it.
    func hvFieldReset<Value: Hashable>(epoch: Int, focus: FocusState<Value>.Binding, field: Value) -> some View {
        modifier(HVFieldResetModifier(epoch: epoch, focus: focus, field: field))
    }
}

struct HVFieldResetModifier<Value: Hashable>: ViewModifier {
    let epoch: Int
    var focus: FocusState<Value>.Binding
    let field: Value

    func body(content: Content) -> some View {
        content
            .id(epoch)
            // The old field goes at once. A cross-fade would leave it first responder while the new one waits.
            .transition(.identity)
            .onChange(of: epoch) {
                // Read in the pass that swaps the field: the old one still holds the keyboard.
                guard focus.wrappedValue == field else { return }
                Task { @MainActor in
                    // By now SwiftUI has either moved the keyboard to the new field (nothing to do) or let it go.
                    if focus.wrappedValue != field { focus.wrappedValue = field }
                }
            }
    }
}
