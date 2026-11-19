import AppKit
import Foundation

/// Shared row builders so every DIZUN window has one visual rhythm: a fixed
/// label column, 8pt gaps, leading alignment, secondary-color hints.
enum DizunRows {
    /// Label column width shared by all setting rows (labels align vertically).
    static let labelWidth: CGFloat = 120

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth).isActive = true
        return field
    }

    static func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .tertiaryLabelColor
        return field
    }

    static func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    /// A settings row: label column, then controls, then an optional hint.
    static func row(label: String, controls: [NSView], hint: String? = nil) -> NSStackView {
        var views: [NSView] = []
        let text = self.label(label)
        text.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        views.append(text)
        views.append(contentsOf: controls)
        if let hint {
            views.append(self.hint(hint))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)
        return stack
    }

    /// A vertical group of rows with consistent breathing room.
    static func group(_ rows: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func segmented(_ labels: [String], target: AnyObject?,
                          action: Selector, selected: Int) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                         target: target, action: action)
        control.segmentStyle = .texturedRounded
        control.selectedSegment = selected
        return control
    }
}
