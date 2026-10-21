import XCTest

final class TileLayoutTests: XCTestCase {
    private let height = CGFloat(50)
    private let padding = CGFloat(10)

    private func packedHeight(_ widths: [CGFloat?], _ widthMax: CGFloat, leftToRight: Bool = true) -> CGFloat {
        TileLayoutTestable.packedHeight(widths, tileHeight: height, padding: padding, widthMax: widthMax, leftToRight: leftToRight)
    }

    func testTilesThatFitStayOnOneRow() throws {
        // x: 10 → 120 → 230 → 340 ≤ 400
        XCTAssertEqual(packedHeight([100, 100, 100], 400), 70)
    }

    func testOverflowingTileStartsANewRow() throws {
        // the 4th tile would end at 450 > 400
        XCTAssertEqual(packedHeight([100, 100, 100, 100], 400), 130)
        XCTAssertEqual(packedHeight([100, 100, 100, 100, 100, 100, 100], 400), 190)
    }

    func testTilesNotDisplayedTakeNoSpace() throws {
        XCTAssertEqual(packedHeight([100, nil, 100, nil, 100, 100, nil], 400), packedHeight([100, 100, 100, 100], 400))
    }

    func testNoTileIsOneEmptyRow() throws {
        XCTAssertEqual(packedHeight([], 400), 70)
        XCTAssertEqual(packedHeight([nil, nil], 400), 70)
    }

    func testRightToLeftPacksLikeLeftToRight() throws {
        let widths: [CGFloat?] = [120, 300, 80, nil, 250, 250, 90, 410, 60, 60, 60, 200]
        for widthMax in stride(from: CGFloat(300), through: 1200, by: 37) {
            XCTAssertEqual(packedHeight(widths, widthMax, leftToRight: false), packedHeight(widths, widthMax), "widthMax=\(widthMax)")
        }
    }

    func testNarrowerGridIsNeverShorter() throws {
        let widths: [CGFloat?] = (0..<190).map(varied)
        var previous = CGFloat.greatestFiniteMagnitude
        for widthMax in stride(from: CGFloat(400), through: 3000, by: 50) {
            let height = packedHeight(widths, widthMax)
            XCTAssertLessThanOrEqual(height, previous, "widthMax=\(widthMax)")
            previous = height
        }
    }

    private func varied(_ index: Int) -> CGFloat? {
        guard index % 7 != 0 else { return nil }
        let extra: Int = (index * 37) % 220
        return CGFloat(80 + extra)
    }

    func testTileWidthAddsInsetsAndKeepsTheMinimum() throws {
        XCTAssertEqual(TileLayoutTestable.tileWidth(contentWidth: 200.4, edgeInsets: 5, widthMin: 100), 210)
        XCTAssertEqual(TileLayoutTestable.tileWidth(contentWidth: 10, edgeInsets: 5, widthMin: 100.6), 101)
    }
}
