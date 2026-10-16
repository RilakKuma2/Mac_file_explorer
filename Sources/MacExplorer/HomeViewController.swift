import AppKit

private final class HomeDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// Home cards activate on a double-click. The first click only focuses the
/// control because these cards do not maintain a persistent selection model.
private final class HomeDoubleClickButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }
}

protocol HomeViewControllerDelegate: AnyObject {
    func homeView(_ homeView: HomeViewController, didOpen url: URL)
}

final class HomeViewController: NSViewController {
    weak var delegate: HomeViewControllerDelegate?

    private let contentStack = NSStackView()
    private weak var quickAccessGrid: NSGridView?
    private var locations: [(title: String, url: URL)] = []
    private var recentURLs: [URL] = []
    private var spotlightRecentURLs: [URL] = []
    private var filterText = ""
    private var recentOnly = false
    private let recentQuery = NSMetadataQuery()
    private var recentQueryObservers: [NSObjectProtocol] = []
    private(set) var isContentVisible = false
    private var needsRebuild = true

    func setContentVisible(_ visible: Bool) {
        guard isContentVisible != visible else { return }
        isContentVisible = visible
        guard isViewLoaded else { return }
        if visible {
            startRecentQuery()
            if needsRebuild { rebuild() }
        } else {
            recentQuery.stop()
            needsRebuild = true
        }
    }

    var visibleRecentCount: Int { recentURLs.count }
    var hasKeyboardFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    func focus() {
        guard let window = view.window else { return }
        if let button = firstEnabledButton(in: view) {
            window.makeFirstResponder(button)
        } else {
            window.makeFirstResponder((view as? NSScrollView)?.documentView)
        }
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        let document = HomeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 24, right: 24)
        document.addSubview(contentStack)
        scrollView.documentView = document

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
        ])
        view = scrollView
        if isContentVisible { startRecentQuery() }
        rebuild()
    }

    deinit {
        recentQuery.stop()
        recentQueryObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func setFilter(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != filterText else { return }
        filterText = normalized
        needsRebuild = true
        if isViewLoaded && isContentVisible { rebuild() }
    }

    func setRecentOnly(_ enabled: Bool) {
        guard recentOnly != enabled else { return }
        recentOnly = enabled
        needsRebuild = true
        if isViewLoaded && isContentVisible { rebuild() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let grid = quickAccessGrid else { return }
        let usableWidth = max(300, view.bounds.width - 48)
        let columnWidth = min(330, max(140, usableWidth * 0.38))
        grid.column(at: 0).width = columnWidth
        grid.column(at: 1).width = columnWidth
    }

    private func rebuild() {
        needsRebuild = false
        quickAccessGrid = nil
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        locations = quickAccessLocations().filter {
            filterText.isEmpty || $0.title.localizedCaseInsensitiveContains(filterText)
        }

        if !recentOnly {
            let headingRow = NSStackView()
            headingRow.orientation = .horizontal
            headingRow.spacing = 10
            let disclosure = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage())
            disclosure.contentTintColor = .labelColor
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            disclosure.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let heading = NSTextField(labelWithString: L10n.text("Quick access"))
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            headingRow.addArrangedSubview(disclosure)
            headingRow.addArrangedSubview(heading)
            contentStack.addArrangedSubview(headingRow)
            contentStack.setCustomSpacing(6, after: headingRow)

            if locations.isEmpty {
                let empty = NSTextField(labelWithString: L10n.text("No matching locations"))
                empty.textColor = .secondaryLabelColor
                contentStack.addArrangedSubview(empty)
            } else {
                let rows = stride(from: 0, to: locations.count, by: 2).map { index -> [NSView] in
                    var row: [NSView] = [makeLocationCard(at: index)]
                    if locations.indices.contains(index + 1) {
                        row.append(makeLocationCard(at: index + 1))
                    } else {
                        row.append(NSView())
                    }
                    return row
                }
                let grid = NSGridView(views: rows)
                grid.translatesAutoresizingMaskIntoConstraints = false
                grid.rowSpacing = 0
                grid.columnSpacing = 14
                grid.column(at: 0).width = 300
                grid.column(at: 1).width = 300
                quickAccessGrid = grid
                contentStack.addArrangedSubview(grid)
                contentStack.setCustomSpacing(8, after: grid)
            }

            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.spacing = 8
            chips.addArrangedSubview(makeChip(title: L10n.text("Favorites"), symbol: "star", selected: true, action: nil))
            chips.addArrangedSubview(makeChip(title: L10n.text("Shared"), symbol: "person.2", selected: false, action: #selector(openShared(_:))))
            contentStack.addArrangedSubview(chips)
        }

        let recentHeading = NSTextField(labelWithString: L10n.text("Recent"))
        recentHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        contentStack.addArrangedSubview(recentHeading)

        let appRecents = NSDocumentController.shared.recentDocumentURLs
        var seen = Set<String>()
        recentURLs = (spotlightRecentURLs + appRecents).filter {
            FileManager.default.fileExists(atPath: $0.path)
                && seen.insert($0.standardizedFileURL.path).inserted
                && (filterText.isEmpty || FileManager.default.displayName(atPath: $0.path).localizedCaseInsensitiveContains(filterText))
        }
        if recentURLs.isEmpty {
            let recentHint = NSTextField(labelWithString: L10n.text("Files opened in Mac Explorer will appear here."))
            recentHint.textColor = .secondaryLabelColor
            recentHint.font = .systemFont(ofSize: 13)
            contentStack.addArrangedSubview(recentHint)
        } else {
            let recentStack = NSStackView()
            recentStack.orientation = .vertical
            recentStack.alignment = .leading
            recentStack.spacing = 2
            for (index, url) in recentURLs.prefix(8).enumerated() {
                let button = HomeDoubleClickButton()
                button.title = FileManager.default.displayName(atPath: url.path)
                button.image = NSWorkspace.shared.icon(forFile: url.path)
                button.imagePosition = .imageLeading
                button.alignment = .left
                button.bezelStyle = .accessoryBarAction
                button.isBordered = false
                button.tag = index
                button.target = self
                button.action = #selector(openRecent(_:))
                button.toolTip = url.path
                button.widthAnchor.constraint(equalToConstant: 520).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                recentStack.addArrangedSubview(button)
            }
            contentStack.addArrangedSubview(recentStack)
        }
    }

    private func firstEnabledButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton,
           button.isEnabled, !button.isHidden, button.alphaValue > 0 {
            return button
        }
        for subview in root.subviews {
            if let button = firstEnabledButton(in: subview) { return button }
        }
        return nil
    }

    private func startRecentQuery() {
        if !recentQueryObservers.isEmpty {
            recentQuery.start()
            return
        }
        guard recentQueryObservers.isEmpty else { return }
        recentQuery.searchScopes = [NSMetadataQueryUserHomeScope]
        recentQuery.predicate = NSPredicate(
            format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree == %@",
            Date(timeIntervalSince1970: 0) as NSDate,
            "public.data"
        )
        recentQuery.sortDescriptors = [
            NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)
        ]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            recentQueryObservers.append(center.addObserver(
                forName: name,
                object: recentQuery,
                queue: .main
            ) { [weak self] _ in self?.consumeRecentQueryResults() })
        }
        recentQuery.start()
    }

    private func consumeRecentQueryResults() {
        guard isContentVisible else { return }
        recentQuery.disableUpdates()
        spotlightRecentURLs = recentQuery.results.prefix(250).compactMap { result in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
        recentQuery.enableUpdates()
        needsRebuild = true
        if isViewLoaded && isContentVisible { rebuild() }
    }

    private func quickAccessLocations() -> [(title: String, url: URL)] {
        let manager = FileManager.default
        let definitions: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, L10n.text("Desktop")),
            (.downloadsDirectory, L10n.text("Downloads")),
            (.documentDirectory, L10n.text("Documents")),
            (.picturesDirectory, L10n.text("Pictures")),
            (.musicDirectory, L10n.text("Music")),
            (.moviesDirectory, L10n.text("Movies"))
        ]
        return definitions.compactMap { directory, title in
            manager.urls(for: directory, in: .userDomainMask).first.map { (title, $0) }
        }
    }

    private func makeLocationCard(at index: Int) -> NSView {
        let location = locations[index]
        let button = HomeDoubleClickButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.tag = index
        button.target = self
        button.action = #selector(openLocation(_:))
        button.toolTip = location.url.path

        let icon = NSImageView(image: FileIconProvider.shared.folderIcon())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        button.addSubview(icon)

        let title = NSTextField(labelWithString: location.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .medium)
        button.addSubview(title)

        let subtitle = NSTextField(labelWithString: L10n.text("Stored locally"))
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 11)
        button.addSubview(subtitle)

        let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: L10n.text("Pinned")) ?? NSImage())
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.contentTintColor = .tertiaryLabelColor
        button.addSubview(pin)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: button.topAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            pin.leadingAnchor.constraint(equalTo: subtitle.trailingAnchor, constant: 8),
            pin.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 12),
            pin.heightAnchor.constraint(equalToConstant: 12)
        ])
        return button
    }

    private func makeChip(title: String, symbol: String, selected: Bool, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: action == nil ? nil : self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        button.contentTintColor = selected ? .controlAccentColor : .labelColor
        return button
    }

    @objc private func openLocation(_ sender: NSButton) {
        guard locations.indices.contains(sender.tag) else { return }
        delegate?.homeView(self, didOpen: locations[sender.tag].url)
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard recentURLs.indices.contains(sender.tag) else { return }
        delegate?.homeView(self, didOpen: recentURLs[sender.tag])
    }

    @objc private func openShared(_ sender: NSButton) {
        let shared = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        if FileManager.default.fileExists(atPath: shared.path) {
            delegate?.homeView(self, didOpen: shared)
        }
    }
}
