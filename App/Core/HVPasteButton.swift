import SwiftUI

// This lives in the app and not in `Shared/DesignSystem`: the Share and Widget extensions compile that folder with
// `APPLICATION_EXTENSION_API_ONLY`, none of them has a Paste button, and the app is the only place the system control is
// used, so an extension never has to build it.

/// The system's Paste control in the app's shape: the one place its border shape and size are set. The system draws
/// the control itself (its label, its icon, and whether it is switched off while the pasteboard is empty), so only
/// the shape and the size are the app's to ask for: a rounded rectangle at the control radius like every other button,
/// and the large control size so it is as tall as one (a regular Paste control measures 34pt, under the 44pt a finger
/// needs). Where a site sets its own tint or identifier it puts them on this view; they pass through to the control.
///
///     HVPasteButton { strings in model.pasted = strings.first ?? "" }
///
/// Whether the system honours the control size and a custom radius on its own control is not something a render can
/// show: look at it on a device. If it stays 34pt tall, the sites give it a 44pt row of their own.
struct HVPasteButton: View {
    let onPaste: ([String]) -> Void

    init(onPaste: @escaping ([String]) -> Void) {
        self.onPaste = onPaste
    }

    var body: some View {
        PasteButton(payloadType: String.self, onPaste: onPaste)
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.roundedRectangle(radius: HV.Radius.control))
            .controlSize(.large)
    }
}
