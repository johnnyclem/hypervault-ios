import SwiftUI
import XCTest
@testable import HyperVault

/// A sheet's Close (handoff 4.4), clean and with something typed in it, beside a decorative symbol. The render is looked
/// at, not compared: the Close is a leading toolbar button with an xmark.
@MainActor
final class SheetCloseSnapshotTests: XCTestCase {
    private func sheet(typed: String) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                HVLabeledField(title: "Name") {
                    TextField("", text: .constant(typed), prompt: .hvPrompt("name"))
                }
                HStack(spacing: HV.Space.xs) {
                    HVIcon(HVSymbol.agentKeys)
                    Text("Agent keys")
                }
                Spacer()
            }
            .padding(HV.Space.m)
            .hvScreenBackground()
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .hvSheetClose(isDirty: !typed.isEmpty)
        }
        .tint(HVColor.primary)
    }

    func testASheetWithItsClose() throws {
        try snapshot(sheet(typed: ""), named: "sheet-close", size: CGSize(width: 393, height: 260))
    }

    func testASheetWithSomethingTypedInIt() throws {
        try snapshot(sheet(typed: "stripe-key"), named: "sheet-close-dirty", size: CGSize(width: 393, height: 260))
    }
}
