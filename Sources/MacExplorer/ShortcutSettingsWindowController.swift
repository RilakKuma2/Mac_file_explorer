import AppKit

final class ShortcutSettingsViewController: NSViewController, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    override func loadView() {
        view = makeContentView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(
            forName: .explorerShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuildRows() }
        rebuildRows()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        rebuildRows()
    }

    private func makeContentView() -> NSView {
        let root = NSView()

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        root.addSubview(header)

        searchField.placeholderString = L10n.text("Search shortcuts")
        searchField.delegate = self
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(searchField)

        let restoreButton = NSButton(
            title: L10n.text("Restore Current Preset"),
            target: self,
            action: #selector(restorePreset(_:))
        )
        restoreButton.bezelStyle = .rounded
        header.addArrangedSubview(restoreButton)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 14, right: 14)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scrollView.documentView = document

        emptyLabel.stringValue = L10n.text("No matching shortcuts")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        rebuildRows()
        return root
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows()
    }

    private func rebuildRows() {
        guard isViewLoaded else { return }
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryOrder = [
            L10n.text("Application"), L10n.text("File"), L10n.text("Edit"),
            L10n.text("View"), L10n.text("Go"), L10n.text("Window"), L10n.text("Tabs")
        ]
        let definitions = ShortcutRegistry.shared.definitions.filter { definition in
            query.isEmpty
                || definition.title.localizedCaseInsensitiveContains(query)
                || definition.category.localizedCaseInsensitiveContains(query)
                || (ShortcutRegistry.shared.binding(for: definition)?.displayString.contains(query) == true)
        }.sorted { lhs, rhs in
            let lhsIndex = categoryOrder.firstIndex(of: lhs.category) ?? categoryOrder.count
            let rhsIndex = categoryOrder.firstIndex(of: rhs.category) ?? categoryOrder.count
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        emptyLabel.isHidden = !definitions.isEmpty

        var previousCategory: String?
        for definition in definitions {
            if definition.category != previousCategory {
                addFullWidthArrangedSubview(makeCategoryHeader(definition.category))
                previousCategory = definition.category
            }
            addFullWidthArrangedSubview(makeRow(for: definition))
        }
    }

    private func addFullWidthArrangedSubview(_ view: NSView) {
        rowsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -28).isActive = true
    }

    private func makeCategoryHeader(_ title: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    private func makeRow(for definition: ShortcutDefinition) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: definition.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)

        let recorder = ShortcutRecorderButton(frame: .zero)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.binding = ShortcutRegistry.shared.binding(for: definition)
        recorder.onRecord = { [weak self, weak recorder] binding in
            self?.record(binding, for: definition, recorder: recorder)
        }
        container.addSubview(recorder)

        let clear = NSButton()
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("Clear"))
        clear.title = ""
        clear.bezelStyle = .accessoryBarAction
        clear.isBordered = false
        clear.toolTip = L10n.text("Clear shortcut")
        clear.target = self
        clear.action = #selector(clearShortcut(_:))
        clear.identifier = NSUserInterfaceItemIdentifier(definition.id)
        container.addSubview(clear)

        let reset = NSButton()
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: L10n.text("Reset"))
        reset.title = ""
        reset.bezelStyle = .accessoryBarAction
        reset.isBordered = false
        reset.toolTip = L10n.text("Restore default shortcut")
        reset.target = self
        reset.action = #selector(resetShortcut(_:))
        reset.identifier = NSUserInterfaceItemIdentifier(definition.id)
        container.addSubview(reset)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 42),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -12),
            recorder.widthAnchor.constraint(equalToConstant: 170),
            recorder.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            recorder.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -7),
            clear.widthAnchor.constraint(equalToConstant: 24),
            clear.heightAnchor.constraint(equalToConstant: 24),
            clear.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: reset.leadingAnchor, constant: -4),
            reset.widthAnchor.constraint(equalToConstant: 24),
            reset.heightAnchor.constraint(equalToConstant: 24),
            reset.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            reset.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func record(
        _ binding: ShortcutBinding,
        for definition: ShortcutDefinition,
        recorder: ShortcutRecorderButton?
    ) {
        let conflicts = ShortcutRegistry.shared.conflicts(for: binding, excluding: definition)
        guard !conflicts.isEmpty else {
            ShortcutRegistry.shared.setBinding(binding, for: definition)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Shortcut already in use")
        alert.informativeText = String(
            format: L10n.text("%@ is already assigned to %@. Replace the existing assignment?"),
            binding.displayString,
            conflicts.map(\.title).joined(separator: ", ")
        )
        alert.addButton(withTitle: L10n.text("Replace"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                recorder?.binding = ShortcutRegistry.shared.binding(for: definition)
                return
            }
            for conflict in conflicts { ShortcutRegistry.shared.setBinding(nil, for: conflict) }
            ShortcutRegistry.shared.setBinding(binding, for: definition)
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let definition = ShortcutRegistry.shared.definitions.first(where: { $0.id == id }) else { return }
        ShortcutRegistry.shared.setBinding(nil, for: definition)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let definition = ShortcutRegistry.shared.definitions.first(where: { $0.id == id }) else { return }
        ShortcutRegistry.shared.resetBinding(for: definition)
    }

    @objc private func restorePreset(_ sender: Any?) {
        ShortcutRegistry.shared.applyPreset(ShortcutProfile.current)
    }
}

final class ShortcutSettingsWindowController: NSWindowController {
    private let editor: ShortcutSettingsViewController

    init() {
        let editor = ShortcutSettingsViewController()
        self.editor = editor
        let window = NSWindow(contentViewController: editor)
        window.title = L10n.text("Keyboard Shortcuts")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() { editor.reload() }
}
