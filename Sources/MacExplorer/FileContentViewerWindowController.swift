import AppKit

final class FileContentViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var retainedControllers: [ObjectIdentifier: FileContentViewerWindowController] = [:]
    private static let readLimit = 4 * 1_024 * 1_024
    private static let hexLimit = 512 * 1_024

    private let url: URL
    private let modeControl = NSSegmentedControl(labels: [L10n.text("Text"), L10n.text("Hex")], trackingMode: .selectOne, target: nil, action: nil)
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var data = Data()
    private var fileSize: Int64 = 0
    private var likelyBinary = false

    static func present(url: URL) {
        let controller = FileContentViewerWindowController(url: url)
        retainedControllers[ObjectIdentifier(controller)] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL) {
        self.url = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: L10n.text("View %@"), url.lastPathComponent)
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        loadFilePrefix()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        Self.retainedControllers.removeValue(forKey: ObjectIdentifier(self))
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        root.addSubview(header)

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        header.addArrangedSubview(icon)
        let path = NSTextField(labelWithString: url.path)
        path.lineBreakMode = .byTruncatingMiddle
        path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(path)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        header.addArrangedSubview(modeControl)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        root.addSubview(scroll)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 520)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.documentView = textView

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -7),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        return root
    }

    private func loadFilePrefix() {
        statusLabel.stringValue = L10n.text("Loading") + "…"
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (Data, Int64) in
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.readLimit) ?? Data()
                return (data, size)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success((data, size)):
                    self.data = data
                    self.fileSize = size
                    self.likelyBinary = data.prefix(8_192).contains(0)
                    self.modeControl.selectedSegment = self.likelyBinary ? 1 : 0
                    self.render()
                case let .failure(error):
                    self.textView.string = error.localizedDescription
                    self.statusLabel.stringValue = L10n.text("Could not read file")
                }
            }
        }
    }

    @objc private func changeMode(_ sender: Any?) { render() }

    private func render() {
        if modeControl.selectedSegment == 1 {
            textView.string = hexDump(data.prefix(Self.hexLimit))
        } else {
            textView.string = decodedText(data)
        }
        textView.scrollToBeginningOfDocument(nil)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let shownCount = modeControl.selectedSegment == 1 ? min(data.count, Self.hexLimit) : data.count
        let shown = formatter.string(fromByteCount: Int64(shownCount))
        let total = formatter.string(fromByteCount: fileSize)
        statusLabel.stringValue = shownCount < fileSize
            ? String(format: L10n.text("Showing first %@ of %@"), shown, total)
            : String(format: L10n.text("%@ total"), total)
    }

    private func decodedText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return L10n.text("This file cannot be decoded as text. Switch to Hex view.")
    }

    private func hexDump(_ bytes: Data.SubSequence) -> String {
        let data = Data(bytes)
        var lines: [String] = []
        lines.reserveCapacity((data.count + 15) / 16)
        for offset in stride(from: 0, to: data.count, by: 16) {
            let end = min(data.count, offset + 16)
            let slice = data[offset..<end]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = slice.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08X  %@  %@", offset, hex, String(ascii)))
        }
        return lines.joined(separator: "\n")
    }
}
