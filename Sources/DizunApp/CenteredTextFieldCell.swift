import AppKit

/// A text-field cell that vertically centers its text. The classic bordered
/// cell pins the title to the top of a taller-than-natural field; drawing
/// the interior ourselves with the same frame math keeps the look while the
/// text sits midway.
final class DizunCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        // Prefer the natural (single-line) height, centered in `rect`.
        let natural = super.drawingRect(forBounds: rect)
        guard natural.height < rect.height - 1 else { return natural }
        let centered = NSRect(
            x: rect.origin.x,
            y: rect.origin.y + (rect.height - natural.height) / 2,
            width: rect.width,
            height: natural.height)
        return super.drawingRect(forBounds: centered)
    }
}
