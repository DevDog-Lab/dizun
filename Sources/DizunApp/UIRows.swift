import AppKit
import Foundation

/// Shared row builders so every DIZUN window has one visual rhythm: a fixed
/// label column, compact control groups, and hints directly beneath controls.
enum DizunRows {
    /// Label column width shared by all setting rows (labels align vertically).
    static let labelWidth: CGFloat = 144

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Row labels that sit on the brand-blue panels read best in white.
    static func tintedLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.textColor = .white
        return field
    }

    static func tintedHint(_ text: String) -> NSTextField {
        let field = hint(text)
        field.textColor = NSColor.white.withAlphaComponent(0.75)
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

    /// A fixed label column followed by a compact control group. Hints belong
    /// to that group so they never drift to the trailing edge of the window.
    static func row(label: String, controls: [NSView], hint: String? = nil,
                    tinted: Bool = false) -> NSStackView {
        let text = tinted ? tintedLabel(label) : self.label(label)
        let controlLine = NSStackView(views: controls)
        controlLine.orientation = .horizontal
        controlLine.spacing = 8
        controlLine.alignment = .centerY
        controlLine.setHuggingPriority(.required, for: .horizontal)

        var detailViews: [NSView] = [controlLine]
        if let hint {
            detailViews.append(tinted ? tintedHint(hint) : self.hint(hint))
        }
        let details = NSStackView(views: detailViews)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4

        let stack = NSStackView(views: [text, details])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .firstBaseline
        stack.setHuggingPriority(.required, for: .horizontal)
        // Both views already belong to the row before constraints are activated.
        text.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
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
