import AppKit

final class SettingsWindowController: NSWindowController {
    private let languagePopup = NSPopUpButton()
    private let conflictPopup = NSPopUpButton()
    private let shortcutPresetPopup = NSPopUpButton()
    private let accessStatus = NSTextField(wrappingLabelWithString: "")
    private let shortcutEditor = ShortcutSettingsViewController()
    private let recentsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let trashCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let desktopHandlerCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.title = L10n.text("Settings")
        let window = NSWindow(contentViewController: tabs)
        window.title = L10n.text("Settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 650))
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        self.init(window: window)

        tabs.addTabViewItem(makeTab(
            title: L10n.text("General"), symbol: "gearshape", viewController: makeGeneralController()
        ))
        tabs.addTabViewItem(makeTab(
            title: L10n.text("Sidebar"), symbol: "sidebar.left", viewController: makeSidebarController()
        ))
        tabs.addTabViewItem(makeTab(
            title: L10n.text("Keyboard Shortcuts"), symbol: "keyboard", viewController: makeShortcutsController()
        ))
        tabs.addTabViewItem(makeTab(
            title: L10n.text("Privacy"), symbol: "hand.raised", viewController: makePrivacyController()
        ))
        window.title = L10n.text("Settings")
    }

    override func showWindow(_ sender: Any?) {
        syncControls()
        shortcutEditor.reload()
        super.showWindow(sender)
    }

    private func makeTab(title: String, symbol: String, viewController: NSViewController) -> NSTabViewItem {
        viewController.title = L10n.text("Settings")
        let item = NSTabViewItem(viewController: viewController)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func makeGeneralController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        let stack = settingsStack(in: root)

        stack.addArrangedSubview(heading(L10n.text("Language")))
        let languageRow = row(label: L10n.text("App language"), control: languagePopup, labelWidth: 190)
        AppLanguage.allCases.forEach { languagePopup.addItem(withTitle: $0.title) }
        languagePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(languageRow)
        let applyButton = NSButton(title: L10n.text("Apply and Relaunch"), target: self, action: #selector(applyLanguage(_:)))
        applyButton.bezelStyle = .rounded
        stack.addArrangedSubview(applyButton)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading(L10n.text("Keyboard shortcuts")))
        ShortcutProfile.allCases.forEach { conflictPopup.addItem(withTitle: $0.title) }
        conflictPopup.target = self
        conflictPopup.action = #selector(changeConflictProfile(_:))
        conflictPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(row(
            label: L10n.text("When shortcuts conflict"), control: conflictPopup, labelWidth: 190
        ))
        let conflictNote = note(L10n.text("This is the default conflict policy. The Shortcuts tab also provides complete per-command editing and preset reset buttons."))
        stack.addArrangedSubview(conflictNote)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading(L10n.text("Desktop integration")))
        desktopHandlerCheckbox.title = L10n.text("Open Finder Desktop folders in Mac Explorer")
        desktopHandlerCheckbox.target = self
        desktopHandlerCheckbox.action = #selector(changeDesktopHandler(_:))
        stack.addArrangedSubview(desktopHandlerCheckbox)
        stack.addArrangedSubview(note(L10n.text("Keeps the Finder Desktop unchanged and intercepts only folder double-clicks. macOS Accessibility permission is required while this option is enabled.")))

        controller.view = root
        return controller
    }

    private func makeSidebarController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        let stack = settingsStack(in: root)
        stack.addArrangedSubview(heading(L10n.text("Sidebar items")))

        recentsCheckbox.title = L10n.text("Show Recent items")
        recentsCheckbox.target = self
        recentsCheckbox.action = #selector(changeSidebarItems(_:))
        stack.addArrangedSubview(recentsCheckbox)

        trashCheckbox.title = L10n.text("Show Trash")
        trashCheckbox.target = self
        trashCheckbox.action = #selector(changeSidebarItems(_:))
        stack.addArrangedSubview(trashCheckbox)
        stack.addArrangedSubview(note(L10n.text("Finder favorites, iCloud locations, mounted disks, network locations, Recent items, and Trash are shown together in the Explorer sidebar.")))
        controller.view = root
        return controller
    }

    private func makeShortcutsController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        root.addSubview(header)

        let presetLabel = NSTextField(labelWithString: L10n.text("Shortcut preset"))
        presetLabel.font = .systemFont(ofSize: 13, weight: .medium)
        header.addArrangedSubview(presetLabel)
        ShortcutProfile.allCases.forEach { shortcutPresetPopup.addItem(withTitle: $0.title) }
        shortcutPresetPopup.target = self
        shortcutPresetPopup.action = #selector(changeShortcutPreset(_:))
        header.addArrangedSubview(shortcutPresetPopup)
        let hint = NSTextField(labelWithString: L10n.text("Select a command below, then press the desired keys."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(hint)

        controller.addChild(shortcutEditor)
        shortcutEditor.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(shortcutEditor.view)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            shortcutEditor.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shortcutEditor.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shortcutEditor.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            shortcutEditor.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        controller.view = root
        return controller
    }

    private func makePrivacyController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        let stack = settingsStack(in: root)
        stack.addArrangedSubview(heading(L10n.text("File Access")))
        stack.addArrangedSubview(note(L10n.text("Choose a folder once and Mac Explorer will remember the access you approved. Choosing your Home folder covers the usual Desktop, Documents, Downloads, and Pictures locations.")))
        accessStatus.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(accessStatus)
        stack.addArrangedSubview(note(L10n.text("For locations outside the selected folder, macOS may still show a Files & Folders prompt. Full Disk Access is only needed for system-wide protected data; Mac Explorer requests a list entry automatically, but you must turn it on yourself.")))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(NSButton(title: L10n.text("Choose Home Folder"), target: self, action: #selector(chooseFolder(_:))))
        buttons.addArrangedSubview(NSButton(title: L10n.text("Files & Folders Settings"), target: self, action: #selector(openFilesAndFolders(_:))))
        stack.addArrangedSubview(buttons)
        let advanced = NSButton(title: L10n.text("Open Full Disk Access") + "…", target: self, action: #selector(openFullDiskAccess(_:)))
        advanced.bezelStyle = .inline
        stack.addArrangedSubview(advanced)
        controller.view = root
        return controller
    }

    private func settingsStack(in root: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
        return stack
    }

    private func row(label: String, control: NSView, labelWidth: CGFloat) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(control)
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 700
        label.maximumNumberOfLines = 4
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 720).isActive = true
        return box
    }

    private func syncControls() {
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.selectedLanguage) ?? 0)
        let profileIndex = ShortcutProfile.allCases.firstIndex(of: ShortcutProfile.current) ?? 0
        conflictPopup.selectItem(at: profileIndex)
        shortcutPresetPopup.selectItem(at: profileIndex)
        recentsCheckbox.state = ExplorerPreferences.showRecentsInSidebar ? .on : .off
        trashCheckbox.state = ExplorerPreferences.showTrashInSidebar ? .on : .off
        desktopHandlerCheckbox.state = ExplorerPreferences.openFinderDesktopFoldersInExplorer ? .on : .off
        updateAccessStatus()
    }

    private func updateAccessStatus() {
        if let url = FolderAccessManager.shared.grantedURL {
            accessStatus.stringValue = L10n.text("Allowed folder") + ": " + url.path
            accessStatus.textColor = .systemGreen
        } else {
            accessStatus.stringValue = L10n.text("No remembered folder access")
            accessStatus.textColor = .secondaryLabelColor
        }
    }

    @objc private func changeConflictProfile(_ sender: Any?) {
        applyShortcutPreset(index: conflictPopup.indexOfSelectedItem)
    }

    @objc private func changeShortcutPreset(_ sender: Any?) {
        applyShortcutPreset(index: shortcutPresetPopup.indexOfSelectedItem)
    }

    private func applyShortcutPreset(index: Int) {
        guard ShortcutProfile.allCases.indices.contains(index) else { return }
        ShortcutRegistry.shared.applyPreset(ShortcutProfile.allCases[index])
        syncControls()
        shortcutEditor.reload()
    }

    @objc private func changeSidebarItems(_ sender: Any?) {
        ExplorerPreferences.showRecentsInSidebar = recentsCheckbox.state == .on
        ExplorerPreferences.showTrashInSidebar = trashCheckbox.state == .on
    }

    @objc private func changeDesktopHandler(_ sender: Any?) {
        let enable = desktopHandlerCheckbox.state == .on
        FinderDesktopOpenInterceptor.shared.restoreLegacyGlobalFolderRegistrationIfNeeded()
        ExplorerPreferences.openFinderDesktopFoldersInExplorer = enable
        ExplorerDesktopManager.shared.setEnabled(false)
        FinderDesktopOpenInterceptor.shared.setEnabled(enable, presentingWindow: window)
        syncControls()
    }

    @objc private func chooseFolder(_ sender: Any?) {
        FolderAccessManager.shared.requestAccess(from: window) { [weak self] granted in
            if granted { self?.updateAccessStatus() }
        }
    }

    @objc private func openFilesAndFolders(_ sender: Any?) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func applyLanguage(_ sender: Any?) {
        guard AppLanguage.allCases.indices.contains(languagePopup.indexOfSelectedItem) else { return }
        let selected = AppLanguage.allCases[languagePopup.indexOfSelectedItem]
        guard selected != L10n.selectedLanguage else { return }
        L10n.selectedLanguage = selected
        let alert = NSAlert()
        alert.messageText = L10n.text("Language changed")
        alert.informativeText = L10n.text("Restart Mac Explorer to apply the language throughout the app.")
        alert.addButton(withTitle: L10n.text("Restart Now"))
        alert.addButton(withTitle: L10n.text("Later"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.relaunchApplication()
        }
    }

    private static func relaunchApplication() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { NSApp.terminate(nil); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async { if error == nil { NSApp.terminate(nil) } }
        }
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        FullDiskAccessManager.shared.openSystemSettings()
    }
}
