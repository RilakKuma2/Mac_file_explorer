import AppKit

enum ExplorerLinkKind: Int {
    case symbolic
    case hard
}

struct LinkCreationOptions {
    let kind: ExplorerLinkKind
    let name: String
}

final class LinkCreationAccessoryView: NSView {
    private let kindPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let sourceIsDirectory: Bool

    init(sourceURL: URL, isDirectory: Bool) {
        sourceIsDirectory = isDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        kindPopup.addItems(withTitles: [L10n.text("Symbolic link"), L10n.text("Hard link")])
        if isDirectory { kindPopup.item(at: 1)?.isEnabled = false }
        let ext = isDirectory ? "" : sourceURL.pathExtension
        let stem = ext.isEmpty ? sourceURL.lastPathComponent : sourceURL.deletingPathExtension().lastPathComponent
        nameField.stringValue = stem + " " + L10n.text("link") + (ext.isEmpty ? "" : "." + ext)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("Link type")), kindPopup],
            [NSTextField(labelWithString: L10n.text("Name")), nameField]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 290)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var options: LinkCreationOptions? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let kind = ExplorerLinkKind(rawValue: kindPopup.indexOfSelectedItem) ?? .symbolic
        guard kind != .hard || !sourceIsDirectory else { return nil }
        return LinkCreationOptions(kind: kind, name: name)
    }
}
