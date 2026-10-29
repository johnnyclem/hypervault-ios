import HyperVaultKit
import XCTest
@testable import HyperVault

/// The parts of Drift that are arithmetic and words: where the camera goes for a stop of the tour, and what the button says.
/// (The tour's own order is tested in the Kit, `GraphTourTests`; the timer and the touches that end it belong to the view.)
final class MemoryGraphDriftTests: XCTestCase {
    private let node = ForcePoint(x: 100, y: 50)
    private let middle = CGPoint(x: 200, y: 300)

    // MARK: The camera

    func testACameraFurtherOutThanTheDriftZoomGoesToTheDriftZoom() {
        let camera = ForceGraphCamera(scale: 0.6, translation: CGSize(width: 40, height: -20), userMoved: false)
        let next = camera.centred(on: node, at: middle, minimumScale: 1.2)
        XCTAssertEqual(next.scale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(next.translation.width, 200 - 100 * 1.2, accuracy: 0.0001)
        XCTAssertEqual(next.translation.height, 300 - 50 * 1.2, accuracy: 0.0001)
    }

    func testACameraAlreadyCloserInKeepsItsZoom() {
        let camera = ForceGraphCamera(scale: 2.5)
        let next = camera.centred(on: node, at: middle, minimumScale: 1.2)
        XCTAssertEqual(next.scale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(next.translation.width, 200 - 250, accuracy: 0.0001)
        XCTAssertEqual(next.translation.height, 300 - 125, accuracy: 0.0001)
    }

    func testTheDriftZoomItselfIsKeptAndTheLimitsOfTheZoomAreRespected() {
        XCTAssertEqual(ForceGraphCamera(scale: 1.2).centred(on: node, at: middle, minimumScale: 1.2).scale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(ForceGraphCamera(scale: 1.19).centred(on: node, at: middle, minimumScale: 1.2).scale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(ForceGraphCamera(scale: 6).centred(on: node, at: middle, minimumScale: 1.2).scale, 6, accuracy: 0.0001)
        XCTAssertEqual(ForceGraphCamera(scale: 9).centred(on: node, at: middle, minimumScale: 1.2).scale, 6, accuracy: 0.0001, "the pinch stops at 6 and so does the tour")
    }

    func testTheNodeEndsUpAtTheMiddleWhereverTheCameraWas() {
        for start in [
            ForceGraphCamera(),
            ForceGraphCamera(scale: 0.3, translation: CGSize(width: -500, height: 800), userMoved: true),
            ForceGraphCamera(scale: 4, translation: CGSize(width: 90, height: 90), userMoved: false),
        ] {
            let next = start.centred(on: node, at: middle, minimumScale: 1.2)
            let drawn = next.screen(node)
            XCTAssertEqual(drawn.x, middle.x, accuracy: 0.001)
            XCTAssertEqual(drawn.y, middle.y, accuracy: 0.001)
        }
    }

    func testTheCameraStopsFramingItselfOnceTheTourHasTakenOver() {
        XCTAssertFalse(ForceGraphCamera().userMoved)
        XCTAssertTrue(ForceGraphCamera().centred(on: node, at: middle, minimumScale: 1.2).userMoved)
    }

    // MARK: The button

    func testTheButtonStartsTheTourAndThenStopsIt() {
        let idle = ForceGraphDriftLook(reduceMotion: false, isDrifting: false)
        XCTAssertEqual(idle, ForceGraphDriftLook(reduceMotion: false, isDrifting: false))
        XCTAssertEqual(idle.label, "Drift")
        XCTAssertEqual(idle.symbol, "play.fill")
        XCTAssertFalse(idle.isPressedIn)

        let running = ForceGraphDriftLook(reduceMotion: false, isDrifting: true)
        XCTAssertEqual(running.label, "Stop drifting")
        XCTAssertEqual(running.symbol, "stop.fill")
        XCTAssertTrue(running.isPressedIn, "it has the selected look while the tour runs")
    }

    func testUnderReduceMotionTheButtonIsNextAndNeverLooksPressedIn() {
        for drifting in [false, true] {
            let look = ForceGraphDriftLook(reduceMotion: true, isDrifting: drifting)
            XCTAssertEqual(look.label, "Next")
            XCTAssertEqual(look.symbol, "forward.fill")
            XCTAssertFalse(look.isPressedIn, "nothing is running by itself, so there is nothing to look pressed in")
        }
    }
}
