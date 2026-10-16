import AppKit

extension Notification.Name {
    static let explorerFileShelfDidChange = Notification.Name("ExplorerFileShelfDidChange")
}

final class FileShelf {
    static let shared = FileShelf()
    private static let defaultsKey = "ExplorerFileShelfPaths"

    private(set) var urls: [URL] = []

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        persist()
    }

    func add(_ newURLs: [URL]) {
        var seen = Set(urls.map { $0.standardizedFileURL.path })
        for url in newURLs where FileManager.default.fileExists(atPath: url.path) {
            if seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) }
        }
        changed()
    }

    func remove(at indexes: IndexSet) {
        for index in indexes.sorted(by: >) where urls.indices.contains(index) { urls.remove(at: index) }
        changed()
    }

    func remove(_ removedURLs: [URL]) {
        let paths = Set(removedURLs.map { $0.standardizedFileURL.path })
        urls.removeAll { paths.contains($0.standardizedFileURL.path) }
        changed()
    }

    func clear() {
        urls.removeAll()
        changed()
    }

    private func changed() {
        persist()
        NotificationCenter.default.post(name: .explorerFileShelfDidChange, object: nil)
    }

    private func persist() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }
}

final class ShelfDropButton: NSButton {
    var onURLsDropped: (([URL]) -> Void)?
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        observer = NotificationCenter.default.addObserver(
            forName: .explorerFileShelfDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshShelfCount() }
        refreshShelfCount()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }

    func refreshShelfCount() {
        let count = FileShelf.shared.urls.count
        toolTip = count == 0
            ? L10n.text("File Shelf — drop files here")
            : String(format: L10n.text("File Shelf — %d items"), count)
    }

    private func draggedURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

final class FileShelfWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = FileShelfWindowController()

    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let moveButton = NSButton()
    private let removeButton = NSButton()
    private weak var browser: MainViewController?
    private var observer: NSObjectProtocol?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("File Shelf")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 440, height: 280)
        super.init(window: panel)
        panel.contentView = makeContentView()
        observer = NotificationCenter.default.addObserver(
            forName: .explorerFileShelfDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func present(for browser: MainViewController) {
        self.browser = browser
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        root.addSubview(header)
        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        header.addArrangedSubview(countLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        let addButton = NSButton(title: L10n.text("Add Selection"), target: self, action: #selector(addSelection(_:)))
        header.addArrangedSubview(addButton)
        let clearButton = NSButton(title: L10n.text("Clear"), target: self, action: #selector(clearShelf(_:)))
        header.addArrangedSubview(clearButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        root.addSubview(scroll)
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L10n.text("Name")
        nameColumn.width = 210
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = L10n.text("Location")
        pathColumn.width = 320
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.headerView = nil
        tableView.rowHeight = 31
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openShelfItem(_:))
        scroll.documentView = tableView

        let footer = NSStackView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        root.addSubview(footer)
        removeButton.title = L10n.text("Remove from Shelf")
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        footer.addArrangedSubview(removeButton)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpacer)
        copyButton.title = L10n.text("Copy Here")
        copyButton.target = self
        copyButton.action = #selector(copyHere(_:))
        footer.addArrangedSubview(copyButton)
        moveButton.title = L10n.text("Move Here")
        moveButton.target = self
        moveButton.action = #selector(moveHere(_:))
        footer.addArrangedSubview(moveButton)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        return root
    }

    private func reload() {
        tableView.reloadData()
        countLabel.stringValue = String(format: L10n.text("%d items staged"), FileShelf.shared.urls.count)
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { FileShelf.shared.urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard FileShelf.shared.urls.indices.contains(row), let tableColumn else { return nil }
        let url = FileShelf.shared.urls[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            cell.textField = field
            cell.addSubview(field)
            if identifier.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                cell.imageView = image
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 20),
                    image.heightAnchor.constraint(equalToConstant: 20),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7)
                ])
            } else {
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8).isActive = true
            }
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        if identifier.rawValue == "name" {
            cell.textField?.stringValue = FileManager.default.displayName(atPath: url.path)
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            cell.textField?.stringValue = url.deletingLastPathComponent().path
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 11)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard FileShelf.shared.urls.indices.contains(row) else { return nil }
        return FileShelf.shared.urls[row] as NSURL
    }

    private func updateButtons() {
        let hasItems = !FileShelf.shared.urls.isEmpty
        let canReceive = browser?.currentLocation.folderURL != nil
        copyButton.isEnabled = hasItems && canReceive
        moveButton.isEnabled = hasItems && canReceive
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    @objc private func addSelection(_ sender: Any?) { browser?.addSelectionToShelf(sender) }
    @objc private func clearShelf(_ sender: Any?) { FileShelf.shared.clear() }
    @objc private func removeSelected(_ sender: Any?) { FileShelf.shared.remove(at: tableView.selectedRowIndexes) }
    @objc private func copyHere(_ sender: Any?) { browser?.acceptShelfItems(kind: .copy) }
    @objc private func moveHere(_ sender: Any?) { browser?.acceptShelfItems(kind: .move) }

    @objc private func openShelfItem(_ sender: Any?) {
        guard FileShelf.shared.urls.indices.contains(tableView.clickedRow) else { return }
        let url = FileShelf.shared.urls[tableView.clickedRow]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            browser?.navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
