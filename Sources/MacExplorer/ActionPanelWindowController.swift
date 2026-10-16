import AppKit

private struct ExplorerActionEntry {
    let title: String
    let menuPath: String
    let shortcut: String
    let action: Selector
    let target: AnyObject?
    let sender: NSMenuItem
}

final class ActionPanelWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = ActionPanelWindowController()

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var allActions: [ExplorerActionEntry] = []
    private var filteredActions: [ExplorerActionEntry] = []

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("Action Panel")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 300)
        super.init(window: panel)
        panel.contentView = makeContentView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        reloadActions()
        searchField.stringValue = ""
        applyFilter()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.text("Type an action or menu name")
        searchField.delegate = self
        root.addSubview(searchField)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        root.addSubview(scroll)

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = L10n.text("Action")
        actionColumn.width = 330
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("menu"))
        pathColumn.title = L10n.text("Menu")
        pathColumn.width = 180
        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = L10n.text("Shortcut")
        shortcutColumn.width = 90
        tableView.addTableColumn(actionColumn)
        tableView.addTableColumn(pathColumn)
        tableView.addTableColumn(shortcutColumn)
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(runSelectedAction(_:))
        scroll.documentView = tableView

        let hint = NSTextField(labelWithString: L10n.text("Return runs the selected action · Escape closes"))
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            searchField.heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        return root
    }

    private func reloadActions() {
        allActions.removeAll(keepingCapacity: true)
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            collect(menu: submenu, path: submenu.title)
        }
    }

    private func collect(menu: NSMenu, path: String) {
        for item in menu.items where !item.isSeparatorItem {
            let nextPath = path.isEmpty ? item.title : path + " › " + item.title
            if let submenu = item.submenu {
                collect(menu: submenu, path: nextPath)
            } else if let action = item.action,
                      item.title != L10n.text("Action Panel") + "…" {
                let shortcut = ShortcutBinding.fromMenuItem(item)?.displayString ?? ""
                allActions.append(ExplorerActionEntry(
                    title: item.title,
                    menuPath: path,
                    shortcut: shortcut,
                    action: action,
                    target: item.target,
                    sender: item
                ))
            }
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredActions = allActions.filter {
            query.isEmpty
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.menuPath.localizedCaseInsensitiveContains(query)
                || $0.shortcut.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
        if !filteredActions.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredActions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredActions.indices.contains(row), let tableColumn else { return nil }
        let entry = filteredActions[row]
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        switch identifier.rawValue {
        case "action":
            cell.textField?.stringValue = entry.title
            cell.textField?.font = .systemFont(ofSize: 13, weight: .medium)
            cell.textField?.textColor = .labelColor
        case "menu":
            cell.textField?.stringValue = entry.menuPath
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
        default:
            cell.textField?.stringValue = entry.shortcut
            cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            runSelectedAction(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !filteredActions.isEmpty else { return true }
            tableView.selectRowIndexes(IndexSet(integer: min(filteredActions.count - 1, max(0, tableView.selectedRow + 1))), byExtendingSelection: false)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !filteredActions.isEmpty else { return true }
            tableView.selectRowIndexes(IndexSet(integer: max(0, tableView.selectedRow - 1)), byExtendingSelection: false)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    @objc private func runSelectedAction(_ sender: Any?) {
        guard filteredActions.indices.contains(tableView.selectedRow) else { return }
        let entry = filteredActions[tableView.selectedRow]
        close()
        DispatchQueue.main.async {
            NSApp.sendAction(entry.action, to: entry.target, from: entry.sender)
        }
    }
}
