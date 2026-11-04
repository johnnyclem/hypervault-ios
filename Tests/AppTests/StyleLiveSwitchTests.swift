import HyperVaultKit
import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// The guard for the assumption the whole indirection rests on: a screen that is already on glass changes colour when the
/// look changes, including a button, whose `ButtonStyle` is not a view body. It draws a window, wears a kit, lets the run loop
/// turn, draws it again, takes the kit off and draws a third time.
final class StyleLiveSwitchTests: StyleRuntimeTestCase {
    private struct Probe: View {
        var body: some View {
            VStack(spacing: HV.Space.s) {
                Spacer()
                Button("Continue") {}.buttonStyle(.hvPrimary)
                Button("Delete") {}.buttonStyle(.hvDestructive)
                Text("Page").foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background.ignoresSafeArea())
        }
    }

    /// The stock look in the dark window the probe is drawn in: the tokens' own numbers.
    private var stockPage: UInt32 { HVTokens.stockColors["background"] ?? 0 }
    private var stockAction: UInt32 { HVTokens.appColors["action"] ?? 0 }
    private var stockDestructive: UInt32 { HVTokens.stockColors["destructive"] ?? 0 }

    private func pixels(_ window: LiveWindow, _ what: String) throws -> PixelBuffer {
        try XCTUnwrap(PixelBuffer(window.draw()), "\(what): the render has no pixels")
    }

    func testAButtonAndThePageFollowTheKitWhenItIsWornAndComeBackWhenItIsTakenOff() throws {
        let kit = StyleKitFixtures.newsprint
        let window = LiveWindow(Probe(), scheme: .dark)
        defer { window.close() }
        window.settle()

        let stock = try pixels(window, "stock")
        XCTAssertTrue(PixelBuffer.same(try XCTUnwrap(stock.color(x: 2, y: 4)), stockPage), "the page starts as the stock page")
        XCTAssertTrue(stock.column(x: 30, contains: stockAction), "the primary button starts on the stock action fill")
        XCTAssertTrue(stock.column(x: 30, contains: stockDestructive), "and the destructive one on the stock red")

        StyleRuntime.shared.apply(kit)
        window.settle()
        let themed = try pixels(window, "themed")
        XCTAssertTrue(PixelBuffer.same(try XCTUnwrap(themed.color(x: 2, y: 4)), kit.colors.background.hex), "the page took the kit's background")
        XCTAssertTrue(themed.column(x: 30, contains: kit.colors.action.hex), "the primary button took the kit's action fill, with no navigation and no new view")
        XCTAssertTrue(themed.column(x: 30, contains: kit.colors.destructive.hex), "the destructive button took the kit's red")
        XCTAssertFalse(themed.column(x: 30, contains: stockAction), "and nothing of the old fill is left")
        XCTAssertFalse(themed.column(x: 30, contains: stockDestructive))

        StyleRuntime.shared.apply(nil)
        window.settle()
        let back = try pixels(window, "back to stock")
        XCTAssertTrue(PixelBuffer.same(try XCTUnwrap(back.color(x: 2, y: 4)), stockPage), "the page is the stock page again")
        XCTAssertTrue(back.column(x: 30, contains: stockAction))
        XCTAssertTrue(back.column(x: 30, contains: stockDestructive))
        XCTAssertFalse(back.column(x: 30, contains: kit.colors.destructive.hex))
    }

    func testChangingStraightFromOneKitToAnotherRepaintsToo() throws {
        let window = LiveWindow(Probe(), scheme: .dark)
        defer { window.close() }
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        window.settle()
        StyleRuntime.shared.apply(StyleKitFixtures.glassmorphism)
        window.settle()
        let glass = try pixels(window, "glassmorphism")
        XCTAssertTrue(PixelBuffer.same(try XCTUnwrap(glass.color(x: 2, y: 4)), StyleKitFixtures.glassmorphism.colors.background.hex))
        XCTAssertTrue(glass.column(x: 30, contains: StyleKitFixtures.glassmorphism.colors.action.hex))
        XCTAssertFalse(glass.column(x: 30, contains: StyleKitFixtures.newsprint.colors.destructive.hex))
    }
}
