import AppKit

struct ArchiveCreationOptions {
    let baseName: String
    let format: ArchiveCreationFormat
    let compressionLevel: ArchiveCompressionLevel
}

final class ArchiveCreationAccessoryView: NSView, NSTextFieldDelegate {
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let compressionPopup = NSPopUpButton()
    private let filenamePreview = NSTextField(labelWithString: "")
    private let performanceNote = NSTextField(wrappingLabelWithString: "")
    private let formats: [ArchiveCreationFormat]
    private var selectedCompressionLevel: ArchiveCompressionLevel = .balanced

    init(baseName: String, suggestedFormat: ArchiveCreationFormat = .zip) {
        formats = ArchiveService.availableCreationFormats
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 176))

        nameField.stringValue = baseName
        nameField.placeholderString = L10n.text("Archive name")
        nameField.delegate = self

        var insertedSeparator = false
        for format in formats {
            if !format.isCommon, !insertedSeparator {
                formatPopup.menu?.addItem(.separator())
                insertedSeparator = true
            }
            formatPopup.addItem(withTitle: format.title)
            formatPopup.lastItem?.representedObject = format.rawValue
        }
        if let item = formatPopup.itemArray.first(where: {
            ($0.representedObject as? String) == suggestedFormat.rawValue
        }) {
            formatPopup.select(item)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        compressionPopup.target = self
        compressionPopup.action = #selector(compressionLevelChanged(_:))

        filenamePreview.font = .systemFont(ofSize: 11, weight: .medium)
        filenamePreview.textColor = .secondaryLabelColor
        filenamePreview.lineBreakMode = .byTruncatingMiddle
        performanceNote.font = .systemFont(ofSize: 11)
        performanceNote.textColor = .tertiaryLabelColor
        performanceNote.maximumNumberOfLines = 2

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("Name")), nameField],
            [NSTextField(labelWithString: L10n.text("Archive format")), formatPopup],
            [NSTextField(labelWithString: L10n.text("Compression level")), compressionPopup],
            [NSTextField(labelWithString: L10n.text("File name")), filenamePreview]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addSubview(grid)

        performanceNote.translatesAutoresizingMaskIntoConstraints = false
        addSubview(performanceNote)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            formatPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            compressionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            performanceNote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 104),
            performanceNote.trailingAnchor.constraint(equalTo: trailingAnchor),
            performanceNote.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            performanceNote.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])

        rebuildCompressionLevels()
        updatePreview()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var options: ArchiveCreationOptions? {
        guard let format = selectedFormat else { return nil }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(format.filenameSuffix.lowercased()) {
            name = String(name.dropLast(format.filenameSuffix.count))
        }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return ArchiveCreationOptions(
            baseName: name,
            format: format,
            compressionLevel: selectedCompressionLevel
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }

    @objc private func formatChanged(_ sender: Any?) {
        rebuildCompressionLevels()
        updatePreview()
    }

    @objc private func compressionLevelChanged(_ sender: Any?) {
        guard ArchiveCompressionLevel.allCases.indices.contains(compressionPopup.indexOfSelectedItem) else { return }
        selectedCompressionLevel = ArchiveCompressionLevel.allCases[compressionPopup.indexOfSelectedItem]
    }

    private var selectedFormat: ArchiveCreationFormat? {
        guard let rawValue = formatPopup.selectedItem?.representedObject as? String else { return nil }
        return ArchiveCreationFormat(rawValue: rawValue)
    }

    private func rebuildCompressionLevels() {
        compressionPopup.removeAllItems()
        guard let format = selectedFormat else { return }
        if format.supportsCompressionLevel {
            for level in ArchiveCompressionLevel.allCases {
                compressionPopup.addItem(withTitle: level.title)
            }
            compressionPopup.selectItem(
                at: ArchiveCompressionLevel.allCases.firstIndex(of: selectedCompressionLevel) ?? 1
            )
            compressionPopup.isEnabled = true
        } else {
            compressionPopup.addItem(withTitle: L10n.text("Not applicable"))
            compressionPopup.isEnabled = false
        }

        switch format {
        case .tarZstd:
            performanceNote.stringValue = L10n.text("Zstandard uses all available CPU cores for fast compression.")
        case .tarXz:
            performanceNote.stringValue = L10n.text("XZ uses multiple CPU cores when supported; maximum compression may use more memory.")
        case .sevenZip:
            performanceNote.stringValue = L10n.text("7Z uses multithreaded LZMA2 when an installed 7-Zip helper is available.")
        default:
            performanceNote.stringValue = L10n.text("Balanced is recommended for everyday use.")
        }
    }

    private func updatePreview() {
        guard let format = selectedFormat else {
            filenamePreview.stringValue = ""
            return
        }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(format.filenameSuffix.lowercased()) {
            name = String(name.dropLast(format.filenameSuffix.count))
        }
        filenamePreview.stringValue = name + format.filenameSuffix
    }
}
