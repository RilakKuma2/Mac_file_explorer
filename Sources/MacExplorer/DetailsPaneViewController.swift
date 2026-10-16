import AppKit
import CoreServices
import UniformTypeIdentifiers

private final class DetailsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class DetailsPaneViewController: NSViewController {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let kindValue = NSTextField(wrappingLabelWithString: "—")
    private let modifiedValue = NSTextField(wrappingLabelWithString: "—")
    private let sizeValue = NSTextField(wrappingLabelWithString: "—")
    private let pathValue = NSTextField(wrappingLabelWithString: "—")
    private let metadataStack = NSStackView()
    private let openWithSection = NSStackView()
    private let openWithPopup = NSPopUpButton()
    private let changeAllButton = NSButton()
    private var representedURL: URL?
    private var representedContentType: UTType?
    private var metadataTask: Task<Void, Never>?
    private var displayGeneration = UUID()
    private weak var detailsScrollView: NSScrollView?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)
        detailsScrollView = scrollView

        let document = DetailsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        document.addSubview(stack)

        let heading = NSTextField(labelWithString: L10n.text("Details"))
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(heading)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 190).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.maximumNumberOfLines = 3
        nameLabel.isSelectable = true
        stack.addArrangedSubview(nameLabel)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeProperty(label: L10n.text("Type"), value: kindValue))
        stack.addArrangedSubview(makeProperty(label: L10n.text("Modified"), value: modifiedValue))
        stack.addArrangedSubview(makeProperty(label: L10n.text("Size"), value: sizeValue))
        stack.addArrangedSubview(makeProperty(label: L10n.text("Path"), value: pathValue))

        configureOpenWithSection()
        stack.addArrangedSubview(openWithSection)

        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = 10
        stack.addArrangedSubview(metadataStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        view = root
        display(item: nil)
    }

    deinit { metadataTask?.cancel() }

    func display(item: FileItem?) {
        guard isViewLoaded else { return }
        displayGeneration = UUID()
        let generation = displayGeneration
        metadataTask?.cancel()
        clearMetadata()
        scrollToTop()
        guard let item else {
            representedURL = nil
            representedContentType = nil
            openWithSection.isHidden = true
            iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
            iconView.contentTintColor = .tertiaryLabelColor
            nameLabel.stringValue = L10n.text("Select an item to view its details")
            kindValue.stringValue = "—"
            modifiedValue.stringValue = "—"
            sizeValue.stringValue = "—"
            pathValue.stringValue = "—"
            return
        }

        iconView.contentTintColor = nil
        representedURL = item.url
        iconView.image = FileIconProvider.shared.icon(for: item)
        FileIconProvider.shared.requestThumbnail(for: item, size: CGSize(width: 380, height: 320)) { [weak self] image in
            guard let self, self.representedURL == item.url, let image else { return }
            self.iconView.image = image
        }
        nameLabel.stringValue = item.name
        kindValue.stringValue = item.kind
        modifiedValue.stringValue = item.modifiedAt.map(dateFormatter.string(from:)) ?? "—"
        sizeValue.stringValue = item.isDirectory ? L10n.text("Calculating") + "…" : item.byteCount.map(byteFormatter.string(fromByteCount:)) ?? "—"
        pathValue.stringValue = item.url.path
        configureOpenWith(for: item)

        let loading = NSTextField(labelWithString: L10n.text("Reading metadata") + "…")
        loading.textColor = .secondaryLabelColor
        loading.font = .systemFont(ofSize: 11)
        metadataStack.addArrangedSubview(loading)

        metadataTask = Task { [weak self] in
            let sections = await MetadataInspector.inspect(item)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.displayGeneration == generation,
                      self.representedURL == item.url else { return }
                self.render(sections: sections)
                if item.isDirectory,
                   let total = sections.first(where: { $0.title == L10n.text("Folder contents") })?
                    .properties.first(where: { $0.label == L10n.text("Total size") })?.value {
                    self.sizeValue.stringValue = total
                }
            }
        }
    }

    func display(items: [FileItem]) {
        guard items.count != 1 else {
            display(item: items.first)
            return
        }
        guard !items.isEmpty else {
            display(item: nil)
            return
        }
        guard isViewLoaded else { return }

        displayGeneration = UUID()
        let generation = displayGeneration
        metadataTask?.cancel()
        clearMetadata()
        scrollToTop()
        representedURL = nil
        representedContentType = nil
        openWithSection.isHidden = true
        iconView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        nameLabel.stringValue = String(format: L10n.text("%d items selected"), items.count)
        kindValue.stringValue = L10n.text("Multiple items")
        modifiedValue.stringValue = "—"
        sizeValue.stringValue = L10n.text("Calculating") + "…"

        let parentPaths = Set(items.map { $0.url.deletingLastPathComponent().path })
        pathValue.stringValue = parentPaths.count == 1
            ? (parentPaths.first ?? "—")
            : L10n.text("Multiple locations")

        let loading = NSTextField(labelWithString: L10n.text("Calculating size") + "…")
        loading.textColor = .secondaryLabelColor
        loading.font = .systemFont(ofSize: 11)
        metadataStack.addArrangedSubview(loading)

        metadataTask = Task { [weak self] in
            let sections = await MetadataInspector.inspect(items)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.displayGeneration == generation,
                      self.representedURL == nil else { return }
                self.render(sections: sections)
                if let total = sections.first?
                    .properties.first(where: { $0.label == L10n.text("Total size") })?.value {
                    self.sizeValue.stringValue = total
                }
            }
        }
    }

    private func render(sections: [InspectorSection]) {
        clearMetadata()
        for section in sections {
            metadataStack.addArrangedSubview(makeSeparator())
            let heading = NSTextField(labelWithString: section.title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            metadataStack.addArrangedSubview(heading)
            for property in section.properties {
                let value = NSTextField(wrappingLabelWithString: property.value)
                metadataStack.addArrangedSubview(makeProperty(label: property.label, value: value))
            }
        }
        scrollToTop()
    }

    private func clearMetadata() {
        metadataStack.arrangedSubviews.forEach {
            metadataStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.detailsScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func configureOpenWithSection() {
        openWithSection.orientation = .vertical
        openWithSection.alignment = .leading
        openWithSection.spacing = 7
        openWithSection.isHidden = true

        let separator = makeSeparator()
        openWithSection.addArrangedSubview(separator)
        let heading = NSTextField(labelWithString: L10n.text("Open With"))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        openWithSection.addArrangedSubview(heading)

        openWithPopup.target = self
        openWithPopup.toolTip = L10n.text("Choose the default application for this file type")
        openWithPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        openWithSection.addArrangedSubview(openWithPopup)

        changeAllButton.title = L10n.text("Change All") + "…"
        changeAllButton.bezelStyle = .rounded
        changeAllButton.target = self
        changeAllButton.action = #selector(changeDefaultApplication(_:))
        changeAllButton.toolTip = L10n.text("Use the selected application for all files of this type")
        openWithSection.addArrangedSubview(changeAllButton)
    }

    private func configureOpenWith(for item: FileItem) {
        guard !item.isDirectory else {
            representedContentType = nil
            openWithSection.isHidden = true
            return
        }

        let contentType = item.contentType
            ?? (try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: item.url.pathExtension)
        guard let contentType else {
            representedContentType = nil
            openWithSection.isHidden = true
            return
        }

        let workspace = NSWorkspace.shared
        let defaultApplication = workspace.urlForApplication(toOpen: item.url)?.standardizedFileURL
        var applications = workspace.urlsForApplications(toOpen: item.url)
        if let defaultApplication,
           !applications.contains(where: { $0.standardizedFileURL == defaultApplication }) {
            applications.insert(defaultApplication, at: 0)
        }
        var seen: Set<String> = []
        applications = applications.filter { seen.insert($0.standardizedFileURL.path).inserted }
        applications.sort {
            if $0.standardizedFileURL == defaultApplication { return true }
            if $1.standardizedFileURL == defaultApplication { return false }
            return $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }
        guard !applications.isEmpty else {
            representedContentType = nil
            openWithSection.isHidden = true
            return
        }

        representedContentType = contentType
        openWithPopup.removeAllItems()
        for applicationURL in applications {
            openWithPopup.addItem(withTitle: applicationURL.deletingPathExtension().lastPathComponent)
            guard let menuItem = openWithPopup.lastItem else { continue }
            menuItem.representedObject = applicationURL
            let icon = workspace.icon(forFile: applicationURL.path)
            icon.size = NSSize(width: 16, height: 16)
            menuItem.image = icon
        }
        if let defaultApplication,
           let index = applications.firstIndex(where: { $0.standardizedFileURL == defaultApplication }) {
            openWithPopup.selectItem(at: index)
        }
        openWithSection.isHidden = false
    }

    @objc private func changeDefaultApplication(_ sender: Any?) {
        guard let contentType = representedContentType,
              let applicationURL = openWithPopup.selectedItem?.representedObject as? URL,
              let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
              let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = L10n.text("Change the default application?")
        alert.informativeText = String(
            format: L10n.text("All files of this type will open with %@."),
            applicationURL.deletingPathExtension().lastPathComponent
        )
        alert.addButton(withTitle: L10n.text("Change All"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let status = LSSetDefaultRoleHandlerForContentType(
                contentType.identifier as CFString,
                .all,
                bundleIdentifier as CFString
            )
            guard status != noErr else { return }
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = L10n.text("The default application could not be changed.")
            errorAlert.informativeText = String(format: "OSStatus %d", status)
            errorAlert.beginSheetModal(for: window)
        }
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return separator
    }

    private func makeProperty(label: String, value: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 11, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 12)
        value.maximumNumberOfLines = 6
        value.lineBreakMode = .byTruncatingMiddle
        value.isSelectable = true
        stack.addArrangedSubview(labelField)
        stack.addArrangedSubview(value)
        return stack
    }
}
