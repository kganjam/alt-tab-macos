import Foundation

/// Pure row packing of the switcher's tiles. The auto-size dry run (`TilesView.resolveAutoSize`)
/// uses it to try each size without touching the tile views: updating ~190 views per size used to
/// redo every tile's content three extra times per show and dirty every title for a redraw.
/// Same arithmetic as `TilesView.layoutTileViews`.
class TileLayoutTestable {
    /// Height of the grid when tiles of `widths` (nil: not displayed) are packed into rows no wider than `widthMax`.
    static func packedHeight(_ widths: [CGFloat?], tileHeight: CGFloat, padding: CGFloat, widthMax: CGFloat, leftToRight: Bool) -> CGFloat {
        let startingX = leftToRight ? padding : widthMax - padding
        var currentX = startingX
        var currentY = padding
        var maxY = currentY + tileHeight + padding
        for case let width? in widths {
            let projectedX = projected(currentX, width, padding, leftToRight).rounded(.down)
            guard overflows(projectedX, widthMax, leftToRight) else {
                currentX = projectedX
                continue
            }
            currentY = (currentY + tileHeight + padding).rounded(.down)
            currentX = projected(startingX, width, padding, leftToRight).rounded(.down)
            maxY = max(currentY + tileHeight + padding, maxY)
        }
        return maxY
    }

    static func projected(_ currentX: CGFloat, _ width: CGFloat, _ padding: CGFloat, _ leftToRight: Bool) -> CGFloat {
        leftToRight ? currentX + width + padding : currentX - width - padding
    }

    static func overflows(_ projectedX: CGFloat, _ widthMax: CGFloat, _ leftToRight: Bool) -> Bool {
        leftToRight ? projectedX > widthMax : projectedX < 0
    }

    /// A tile's frame width: its content plus insets, at least `widthMin`.
    static func tileWidth(contentWidth: CGFloat, edgeInsets: CGFloat, widthMin: CGFloat) -> CGFloat {
        max((contentWidth + edgeInsets * 2).rounded(), widthMin).rounded()
    }
}
