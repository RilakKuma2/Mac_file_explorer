import AppKit

private final class NetworkDocumentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class NetworkFocusableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

protocol NetworkViewControllerDelegate: AnyObject {
    func networkView(_ networkView: NetworkViewController, didRequestConnect address: String?)
    func networkView(_ networkView: NetworkViewController, didRequestEditSavedServer address: String?)
    func networkView(_ networkView: NetworkViewController, didOpen volume: URL)
}

final class NetworkViewController: NSViewController {
    weak var delegate: NetworkViewControllerDelegate?

    private let contentStack = NSStackView()
    private var mountedVolumes: [URL] = []
    private var savedServers: [String] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var filterText = ""
    private var isScanningVolumes = false
    private var needsVolumeRescan = false

    var visibleItemCount: Int { mountedVolumes.count + savedServers.count }
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

        let document = NetworkDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 32, right: 32)
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
        observeMounts()
        refreshSavedServers()
        render(isLoading: false)
    }

    func setFilter(_ text: String) {
        let newFilter = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newFilter != filterText else { return }
        filterText = newFilter
        guard isViewLoaded else { return }
        refreshSavedServers()
        render(isLoading: isScanningVolumes)
    }

    func reload() {
        guard isViewLoaded else { return }
        refreshSavedServers()
        if isScanningVolumes {
            needsVolumeRescan = true
            return
        }

        isScanningVolumes = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let volumes = Self.loadMountedNetworkVolumes()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningVolumes = false
                self.mountedVolumes = volumes.filter { url in
                    self.filterText.isEmpty
                        || url.lastPathComponent.localizedCaseInsensitiveContains(self.filterText)
                }
                self.refreshSavedServers()
                self.render(isLoading: false)
                if self.needsVolumeRescan {
                    self.needsVolumeRescan = false
                    self.reload()
                }
            }
        }
    }

    private func refreshSavedServers() {
        savedServers = ServerConnectionManager.shared.savedServers.filter {
            filterText.isEmpty || $0.localizedCaseInsensitiveContains(filterText)
        }
    }

    private func render(isLoading: Bool) {
        guard isViewLoaded else { return }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let heading = NSTextField(labelWithString: L10n.text("Network"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        contentStack.addArrangedSubview(heading)

        let description = NSTextField(wrappingLabelWithString: L10n.text("Connect to Mac, Windows, NAS, and other file servers using SMB, NFS, WebDAV, FTP, or AFP."))
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = 650
        contentStack.addArrangedSubview(description)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let connect = NetworkFocusableButton(title: L10n.text("Connect to Server") + "…", target: self, action: #selector(connectToServer(_:)))
        connect.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: nil)
        connect.imagePosition = .imageLeading
        connect.setAccessibilityLabel(L10n.text("Connect to Server"))
        buttons.addArrangedSubview(connect)
        let finder = NetworkFocusableButton(title: L10n.text("Browse Network in Finder"), target: self, action: #selector(browseInFinder(_:)))
        buttons.addArrangedSubview(finder)
        contentStack.addArrangedSubview(buttons)

        contentStack.addArrangedSubview(sectionHeading(L10n.text("Connected servers")))

        if isLoading && mountedVolumes.isEmpty {
            let loading = NSTextField(wrappingLabelWithString: L10n.text("Loading") + "…")
            loading.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(loading)
        } else if mountedVolumes.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text("No connected servers. Use Connect to Server or browse Network in Finder."))
            empty.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(empty)
        } else {
            for (index, volume) in mountedVolumes.enumerated() {
                let open = rowButton(
                    title: FileManager.default.displayName(atPath: volume.path),
                    symbol: nil,
                    action: #selector(openVolume(_:)),
                    tag: index
                )
                open.image = NSWorkspace.shared.icon(forFile: volume.path)
                open.toolTip = volume.path
                let disconnect = compactButton(
                    title: L10n.text("Disconnect"),
                    symbol: "eject",
                    action: #selector(disconnectVolume(_:)),
                    tag: index
                )
                contentStack.addArrangedSubview(serverRow(primary: open, actions: [disconnect]))
            }
        }

        let savedHeader = NSStackView()
        savedHeader.orientation = .horizontal
        savedHeader.alignment = .centerY
        savedHeader.spacing = 8
        savedHeader.addArrangedSubview(sectionHeading(L10n.text("Saved servers")))
        let add = compactButton(
            title: L10n.text("Add Server"),
            symbol: "plus",
            action: #selector(addSavedServer(_:)),
            tag: 0
        )
        savedHeader.addArrangedSubview(add)
        contentStack.addArrangedSubview(savedHeader)

        if savedServers.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text("No saved servers. Add one for quick access later."))
            empty.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(empty)
        } else {
            for (index, address) in savedServers.enumerated() {
                let connect = rowButton(
                    title: address,
                    symbol: "network",
                    action: #selector(connectSaved(_:)),
                    tag: index
                )
                let edit = compactButton(
                    title: L10n.text("Edit"),
                    symbol: "pencil",
                    action: #selector(editSavedServer(_:)),
                    tag: index
                )
                let remove = compactButton(
                    title: L10n.text("Remove"),
                    symbol: "minus.circle",
                    action: #selector(removeSavedServer(_:)),
                    tag: index
                )
                contentStack.addArrangedSubview(serverRow(primary: connect, actions: [edit, remove]))
            }
        }
    }

    private func sectionHeading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }

    private func rowButton(title: String, symbol: String?, action: Selector, tag: Int) -> NSButton {
        let button = NetworkFocusableButton(title: title, target: self, action: action)
        button.alignment = .left
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageLeading
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        button.tag = tag
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    private func compactButton(title: String, symbol: String, action: Selector, tag: Int) -> NSButton {
        let button = NetworkFocusableButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.tag = tag
        button.toolTip = title
        return button
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

    private func serverRow(primary: NSButton, actions: [NSButton]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(primary)
        actions.forEach(row.addArrangedSubview)
        primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return row
    }

    private static func loadMountedNetworkVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter { url in
            guard url.path != "/", let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsBrowsable != false && values.volumeIsLocal == false
        }
    }

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
    }

    @objc private func connectToServer(_ sender: Any?) { delegate?.networkView(self, didRequestConnect: nil) }

    @objc private func connectSaved(_ sender: NSButton) {
        guard savedServers.indices.contains(sender.tag) else { return }
        delegate?.networkView(self, didRequestConnect: savedServers[sender.tag])
    }

    @objc private func addSavedServer(_ sender: Any?) {
        delegate?.networkView(self, didRequestEditSavedServer: nil)
    }

    @objc private func editSavedServer(_ sender: NSButton) {
        guard savedServers.indices.contains(sender.tag) else { return }
        delegate?.networkView(self, didRequestEditSavedServer: savedServers[sender.tag])
    }

    @objc private func removeSavedServer(_ sender: NSButton) {
        guard savedServers.indices.contains(sender.tag) else { return }
        ServerConnectionManager.shared.remove(savedServers[sender.tag])
        reload()
    }

    @objc private func browseInFinder(_ sender: Any?) {
        do {
            try ServerConnectionManager.shared.browseNetworkInFinder()
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    @objc private func openVolume(_ sender: NSButton) {
        guard mountedVolumes.indices.contains(sender.tag) else { return }
        delegate?.networkView(self, didOpen: mountedVolumes[sender.tag])
    }

    @objc private func disconnectVolume(_ sender: NSButton) {
        guard mountedVolumes.indices.contains(sender.tag) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountedVolumes[sender.tag])
            reload()
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
    }
}
