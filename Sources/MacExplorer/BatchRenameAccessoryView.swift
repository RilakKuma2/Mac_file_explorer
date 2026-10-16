import AppKit

final class BatchRenameAccessoryView: NSView {
    private enum Mode: Int {
        case replace
        case add
        case format
    }

    private let modePopup = NSPopUpButton()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let primaryField = NSTextField()
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let secondaryField = NSTextField()
    private let positionLabel = NSTextField(labelWithString: L10n.text("Position"))
    private let positionPopup = NSPopUpButton()
    private let startLabel = NSTextField(labelWithString: L10n.text("Start numbers at"))
    private let startField = NSTextField(string: "1")
    private let secondaryRow = NSStackView()
    private let positionRow = NSStackView()
    private let startRow = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 170))

        modePopup.addItems(withTitles: [
            L10n.text("Replace Text"),
            L10n.text("Add Text"),
            L10n.text("Format")
        ])
        modePopup.target = self
        modePopup.action = #selector(updateMode(_:))
        positionPopup.addItems(withTitles: [L10n.text("After name"), L10n.text("Before name")])

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        addSubview(stack)
        stack.addArrangedSubview(makeRow(label: NSTextField(labelWithString: L10n.text("Rename method")), control: modePopup))
        stack.addArrangedSubview(makeRow(label: primaryLabel, control: primaryField))

        configure(row: secondaryRow, label: secondaryLabel, control: secondaryField)
        configure(row: positionRow, label: positionLabel, control: positionPopup)
        configure(row: startRow, label: startLabel, control: startField)
        stack.addArrangedSubview(secondaryRow)
        stack.addArrangedSubview(positionRow)
        stack.addArrangedSubview(startRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            primaryField.widthAnchor.constraint(equalToConstant: 270),
            secondaryField.widthAnchor.constraint(equalToConstant: 270),
            positionPopup.widthAnchor.constraint(equalToConstant: 170),
            startField.widthAnchor.constraint(equalToConstant: 90)
        ])
        updateMode(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func proposedNames(for items: [FileItem]) throws -> [String] {
        guard let mode = Mode(rawValue: modePopup.indexOfSelectedItem) else { throw FileSystemServiceError.invalidName }
        let primary = primaryField.stringValue
        let secondary = secondaryField.stringValue
        let before = positionPopup.indexOfSelectedItem == 1
        let start = Int(startField.stringValue) ?? 1

        if mode != .format, primary.isEmpty { throw FileSystemServiceError.invalidName }
        if mode == .replace, primary.isEmpty { throw FileSystemServiceError.invalidName }
        if mode == .format, primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileSystemServiceError.invalidName
        }

        return items.enumerated().map { offset, item in
            let fileExtension = item.isDirectory ? "" : item.url.pathExtension
            let stem = fileExtension.isEmpty
                ? item.url.lastPathComponent
                : item.url.deletingPathExtension().lastPathComponent
            let renamedStem: String
            switch mode {
            case .replace:
                renamedStem = stem.replacingOccurrences(of: primary, with: secondary)
            case .add:
                renamedStem = before ? primary + stem : stem + primary
            case .format:
                let number = start + offset
                renamedStem = before ? "\(number) \(primary)" : "\(primary) \(number)"
            }
            return fileExtension.isEmpty ? renamedStem : "\(renamedStem).\(fileExtension)"
        }
    }

    @objc private func updateMode(_ sender: Any?) {
        let mode = Mode(rawValue: modePopup.indexOfSelectedItem) ?? .replace
        switch mode {
        case .replace:
            primaryLabel.stringValue = L10n.text("Find")
            secondaryLabel.stringValue = L10n.text("Replace with")
            secondaryRow.isHidden = false
            positionRow.isHidden = true
            startRow.isHidden = true
        case .add:
            primaryLabel.stringValue = L10n.text("Text")
            secondaryRow.isHidden = true
            positionRow.isHidden = false
            startRow.isHidden = true
        case .format:
            primaryLabel.stringValue = L10n.text("Custom format")
            secondaryRow.isHidden = true
            positionRow.isHidden = false
            startRow.isHidden = false
        }
    }

    private func makeRow(label: NSTextField, control: NSView) -> NSStackView {
        let row = NSStackView()
        configure(row: row, label: label, control: control)
        return row
    }

    private func configure(row: NSStackView, label: NSTextField, control: NSView) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
    }
}
