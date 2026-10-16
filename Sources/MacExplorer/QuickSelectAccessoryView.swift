import AppKit

struct QuickSelectOptions {
    let pattern: String
    let usesRegularExpression: Bool
    let caseSensitive: Bool
    let includesFolders: Bool
}

final class QuickSelectAccessoryView: NSView {
    private let patternField = NSTextField()
    private let modePopup = NSPopUpButton()
    private let caseCheckbox = NSButton(checkboxWithTitle: L10n.text("Case sensitive"), target: nil, action: nil)
    private let foldersCheckbox = NSButton(checkboxWithTitle: L10n.text("Include folders"), target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 112))
        patternField.placeholderString = "*.jpg; *.png"
        modePopup.addItems(withTitles: [L10n.text("Wildcard"), L10n.text("Regular expression")])
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("Pattern")), patternField],
            [NSTextField(labelWithString: L10n.text("Match mode")), modePopup]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        addSubview(grid)

        let checks = NSStackView(views: [caseCheckbox, foldersCheckbox])
        checks.translatesAutoresizingMaskIntoConstraints = false
        checks.orientation = .horizontal
        checks.spacing = 18
        addSubview(checks)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            checks.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
            checks.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var options: QuickSelectOptions? {
        let value = patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return QuickSelectOptions(
            pattern: value,
            usesRegularExpression: modePopup.indexOfSelectedItem == 1,
            caseSensitive: caseCheckbox.state == .on,
            includesFolders: foldersCheckbox.state == .on
        )
    }
}
