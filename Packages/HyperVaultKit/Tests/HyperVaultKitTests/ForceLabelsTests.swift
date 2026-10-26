import XCTest
@testable import HyperVaultKit

final class ForceLabelsTests: XCTestCase {
    private let screen = CGRect(x: 12, y: 8, width: 369, height: 700)

    private func options(keepOut: [CGRect] = []) -> ForceLabelPlacer.Options {
        ForceLabelPlacer.Options(bounds: screen, keepOut: keepOut)
    }

    private func request(_ id: String, at center: CGPoint, width: CGFloat = 100, priority: Int = 1, required: Bool = false) -> ForceLabelPlacer.Request {
        ForceLabelPlacer.Request(id: id, center: center, radius: 8, size: CGSize(width: width, height: 14), priority: priority, isRequired: required)
    }

    private func disc(_ id: String, at center: CGPoint, radius: CGFloat = 8) -> ForceLabelPlacer.Obstacle {
        ForceLabelPlacer.Obstacle(id: id, rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func testANameGoesUnderItsNodeWhenThereIsRoom() throws {
        let center = CGPoint(x: 200, y: 300)
        let placed = ForceLabelPlacer.place([request("a", at: center)], nodes: [disc("a", at: center)], links: [], options: options())
        let one = try XCTUnwrap(placed.first)
        XCTAssertEqual(one.side, .below)
        XCTAssertEqual(one.frame.midX, 200, accuracy: 0.001)
        XCTAssertEqual(one.frame.minY, 300 + 8 + 3, accuracy: 0.001)
    }

    func testANameMovesOffAnotherNode() throws {
        let a = CGPoint(x: 200, y: 300)
        let b = CGPoint(x: 205, y: 326)
        let placed = ForceLabelPlacer.place([request("a", at: a)], nodes: [disc("a", at: a), disc("b", at: b)], links: [], options: options())
        let one = try XCTUnwrap(placed.first)
        XCTAssertNotEqual(one.side, .below)
        XCTAssertFalse(one.frame.intersects(disc("b", at: b).rect))
    }

    func testANameMovesOffALinkThatRunsThroughIt() throws {
        let a = CGPoint(x: 200, y: 300)
        let across = ForceLabelPlacer.Segment(from: CGPoint(x: 120, y: 322), to: CGPoint(x: 290, y: 322))
        let placed = ForceLabelPlacer.place([request("a", at: a)], nodes: [disc("a", at: a)], links: [across], options: options())
        let one = try XCTUnwrap(placed.first)
        XCTAssertEqual(one.side, .above, "the clear side wins over the first side")
    }

    func testNamesNeverOverlapOneAnother() {
        // A row close enough that each name wants the strip under its neighbour as well.
        let centers = (0..<5).map { CGPoint(x: 60 + CGFloat($0) * 70, y: 200) }
        let requests = centers.enumerated().map { request("n\($0.offset)", at: $0.element, width: 90, priority: 5 - $0.offset) }
        let nodes = centers.enumerated().map { disc("n\($0.offset)", at: $0.element) }
        let placed = ForceLabelPlacer.place(requests, nodes: nodes, links: [], options: options())
        XCTAssertGreaterThanOrEqual(placed.count, 3)
        for (i, first) in placed.enumerated() {
            for second in placed[(i + 1)...] {
                XCTAssertFalse(first.frame.intersects(second.frame), "\(first.id) overlaps \(second.id)")
            }
            for node in nodes where node.id != first.id {
                XCTAssertFalse(first.frame.intersects(node.rect), "\(first.id) covers \(node.id)")
            }
        }
        XCTAssertEqual(placed.first?.id, "n0", "the highest priority is placed first")
    }

    func testANameStaysInsideTheBoundsAndOverItsNode() throws {
        // Close to the left edge, a centred name would be cut off; sliding it would leave the node
        // off its end, so it goes beside the node instead.
        let center = CGPoint(x: 20, y: 300)
        let placed = ForceLabelPlacer.place([request("a", at: center, width: 140)], nodes: [disc("a", at: center)], links: [], options: options())
        let one = try XCTUnwrap(placed.first)
        XCTAssertTrue(screen.contains(one.frame))
        XCTAssertEqual(one.side, .trailing)
        XCTAssertGreaterThan(one.frame.minX, center.x)
    }

    func testANameSlidesAlongItsNodeWhenThatKeepsThemTogether() throws {
        let center = CGPoint(x: 70, y: 300)
        let placed = ForceLabelPlacer.place([request("a", at: center, width: 140)], nodes: [disc("a", at: center)], links: [], options: options())
        let one = try XCTUnwrap(placed.first)
        XCTAssertEqual(one.side, .below)
        XCTAssertGreaterThanOrEqual(one.frame.minX, screen.minX)
        XCTAssertTrue(one.frame.minX...one.frame.maxX ~= center.x)
    }

    func testANameIsLeftOutWhereLinksCrowdIt() {
        let a = CGPoint(x: 200, y: 300)
        // Links all around, through every side.
        let links = [
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 320), to: CGPoint(x: 300, y: 330)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 325), to: CGPoint(x: 300, y: 318)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 330), to: CGPoint(x: 300, y: 322)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 278), to: CGPoint(x: 300, y: 284)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 282), to: CGPoint(x: 300, y: 276)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 100, y: 286), to: CGPoint(x: 300, y: 280)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 226, y: 200), to: CGPoint(x: 232, y: 400)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 230, y: 200), to: CGPoint(x: 236, y: 400)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 234, y: 200), to: CGPoint(x: 240, y: 400)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 168, y: 200), to: CGPoint(x: 174, y: 400)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 164, y: 200), to: CGPoint(x: 170, y: 400)),
            ForceLabelPlacer.Segment(from: CGPoint(x: 160, y: 200), to: CGPoint(x: 166, y: 400)),
        ]
        let quiet = ForceLabelPlacer.place([request("a", at: a)], nodes: [disc("a", at: a)], links: links, options: options())
        XCTAssertTrue(quiet.isEmpty)
        let selected = ForceLabelPlacer.place([request("a", at: a, priority: 3, required: true)], nodes: [disc("a", at: a)], links: links, options: options())
        XCTAssertEqual(selected.count, 1, "a required name is always drawn")
    }

    func testARequiredNameStaysOnScreenEvenWhenEverythingIsTaken() throws {
        let center = CGPoint(x: 8, y: 700)
        let keep = [CGRect(x: 0, y: 0, width: 400, height: 720)]
        let placed = ForceLabelPlacer.place(
            [request("a", at: center, width: 150, priority: 3, required: true)], nodes: [disc("a", at: center)], links: [],
            options: options(keepOut: keep)
        )
        let one = try XCTUnwrap(placed.first)
        XCTAssertTrue(screen.contains(one.frame))
    }

    func testKeepOutAreasAreRespected() throws {
        let center = CGPoint(x: 200, y: 300)
        let legend = CGRect(x: 0, y: 312, width: 400, height: 30)
        let placed = ForceLabelPlacer.place([request("a", at: center)], nodes: [disc("a", at: center)], links: [], options: options(keepOut: [legend]))
        let one = try XCTUnwrap(placed.first)
        XCTAssertFalse(one.frame.intersects(legend))
    }

    func testASegmentAndARectangle() {
        let box = CGRect(x: 10, y: 10, width: 20, height: 10)
        XCTAssertTrue(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 0, y: 15), to: CGPoint(x: 40, y: 15)), box), "straight through")
        XCTAssertTrue(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 15, y: 0), to: CGPoint(x: 15, y: 12)), box), "ends inside")
        XCTAssertTrue(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 12, y: 12), to: CGPoint(x: 14, y: 14)), box), "wholly inside")
        XCTAssertFalse(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 8, y: 30)), box), "passes beside")
        XCTAssertFalse(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 0, y: 25), to: CGPoint(x: 40, y: 25)), box), "runs below")
        XCTAssertFalse(ForceLabelPlacer.intersects(.init(from: CGPoint(x: 0, y: 40), to: CGPoint(x: 0, y: 40)), box), "a point outside")
    }
}
