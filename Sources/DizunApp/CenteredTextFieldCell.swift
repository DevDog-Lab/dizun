import AppKit

/// Keeps the classic white field independent of Liquid Glass bezel drawing.
/// Text and the native field editor share one baseline; the smaller placeholder
/// is centered using its own glyph bounds instead of the value font's metrics.
final class DizunCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let font = self.font ?? .systemFont(ofSize: 12)
        // AppKit's drawingRect is the entire inset interior, NOT a natural
        // line height. Center a single line explicitly, using a stable baseline
        // while typing (including when the field starts empty).
        return NSRect(x: rect.minX + 3,
                      y: rect.midY - ceil(font.ascender) + font.capHeight / 2,
                      width: max(0, rect.width - 6),
                      height: ceil(font.ascender - font.descender))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if drawsBackground, let fill = backgroundColor {
            fill.setFill()
            NSBezierPath(rect: cellFrame).fill()
        }
        NSColor.systemGray.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(rect: cellFrame.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        if stringValue.isEmpty, let placeholder = placeholderAttributedString,
           placeholder.length > 0 {
            let font = placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                ?? self.font ?? .systemFont(ofSize: 12)
            let ink = placeholder.boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                             height: CGFloat.greatestFiniteMagnitude),
                options: .usesDeviceMetrics)
            NSGraphicsContext.saveGraphicsState()
            cellFrame.insetBy(dx: 3, dy: 1).clip()
            placeholder.draw(at: NSPoint(
                x: cellFrame.minX + 3,
                y: cellFrame.midY - ceil(font.ascender) + ink.midY))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Pass the FULL frame: drawInterior calls drawingRect itself.
            // Passing an already centered rect would apply the insets twice.
            super.drawInterior(withFrame: cellFrame, in: controlView)
        }
    }
}
