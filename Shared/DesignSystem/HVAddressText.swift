import HyperVaultKit
import SwiftUI

/// A host, a URL or an email drawn as text that may run over lines.
///
/// A narrow line has no place to break "hooks.example.org" but inside a word, so it breaks it and adds a hyphen
/// ("example.-" then "com"), which reads as part of the address. At an accessibility size, where an address is wider than
/// the line, it is drawn with places to break after its dots, its "@" and its slashes (`AddressText`) and the hyphen is
/// not needed. Up to those sizes it is the plain text, as it was.
///
/// What is drawn is not what is meant: copying, sharing and comparing use the address, and so does VoiceOver, which is
/// told it here. Where the text is selectable, or is put on the pasteboard from what is drawn, use `Text` instead.
struct HVAddressText: View {
    let address: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ address: String) {
        self.address = address
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(verbatim: AddressText.breakable(address))
                .accessibilityLabel(address)
        } else {
            Text(verbatim: address)
        }
    }
}
