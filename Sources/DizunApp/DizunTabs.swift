import AppKit
import Foundation

/// High-contrast tab/choice selector for the brand-blue panels. The macOS 27
/// glass segmented control loses contrast over translucent backgrounds, so
/// DIZUN tabs are standard buttons: selected = white capsule + bold dark
/// text, unselected = plain white text.
final class DizunTabs: NSView {
    var onSelect: ((Int) -> Void)?

    private var buttons: [NSButton] = []
    private(set) var selected: Int

    init(labels: [String], selected: Int) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (index, label) in labels.enumerated() {
            let button = NSButton(title: label, target: self, action: #selector(tapped(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            // Roomy hit target without visual weight.
            button.contentTintColor = .white
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        applySelection()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        selected = index
        applySelection()
    }

    private func applySelection() {
        for (index, button) in buttons.enumerated() {
            let isOn = index == selected
            button.layer?.backgroundColor = isOn
                ? NSColor.white.cgColor
                : NSColor.clear.cgColor
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: isOn
                        ? NSColor.black
                        : NSColor.white.withAlphaComponent(0.92),
                ])
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        select(sender.tag)
        onSelect?(sender.tag)
    }
}
