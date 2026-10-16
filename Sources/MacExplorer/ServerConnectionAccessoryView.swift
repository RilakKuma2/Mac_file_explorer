import AppKit

enum ServerProtocolOption: String, CaseIterable {
    case smb
    case nfs
    case webDAVSecure = "https"
    case webDAV = "http"
    case ftp
    case afp

    var title: String {
        switch self {
        case .smb: return "SMB"
        case .nfs: return "NFS"
        case .webDAVSecure: return "WebDAV (HTTPS)"
        case .webDAV: return "WebDAV (HTTP)"
        case .ftp: return "FTP"
        case .afp: return L10n.text("AFP (Legacy)")
        }
    }

    var example: String {
        switch self {
        case .smb: return "server/share"
        case .nfs: return "server/export/path"
        case .webDAVSecure, .webDAV: return "server/path"
        case .ftp: return "server/path"
        case .afp: return "server/share"
        }
    }

    static func option(forScheme scheme: String?) -> ServerProtocolOption {
        guard let scheme = scheme?.lowercased() else { return .smb }
        if scheme == "cifs" { return .smb }
        return allCases.first(where: { $0.rawValue == scheme }) ?? .smb
    }
}

final class ServerConnectionAccessoryView: NSView {
    private let protocolPopup = NSPopUpButton()
    private let addressField = NSTextField()
    let saveCheckbox: NSButton

    init(initialAddress: String?, showsSaveOption: Bool) {
        saveCheckbox = NSButton(
            checkboxWithTitle: L10n.text("Save to server list"),
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: showsSaveOption ? 104 : 76))

        ServerProtocolOption.allCases.forEach { protocolPopup.addItem(withTitle: $0.title) }
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged(_:))

        let parsed = Self.parse(initialAddress)
        let option = ServerProtocolOption.option(forScheme: parsed.scheme)
        protocolPopup.selectItem(at: ServerProtocolOption.allCases.firstIndex(of: option) ?? 0)
        addressField.stringValue = parsed.remainder
        addressField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        addressField.lineBreakMode = .byTruncatingMiddle

        let protocolLabel = NSTextField(labelWithString: L10n.text("Protocol"))
        let addressLabel = NSTextField(labelWithString: L10n.text("Server address"))
        protocolLabel.alignment = .right
        addressLabel.alignment = .right

        let grid = NSGridView(views: [
            [protocolLabel, protocolPopup],
            [addressLabel, addressField]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).width = 104
        addSubview(grid)

        if showsSaveOption {
            saveCheckbox.state = .on
            saveCheckbox.translatesAutoresizingMaskIntoConstraints = false
            addSubview(saveCheckbox)
        } else {
            saveCheckbox.state = .on
            saveCheckbox.isHidden = true
        }

        var constraints = [
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310)
        ]
        if showsSaveOption {
            constraints += [
                saveCheckbox.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 114),
                saveCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        updatePlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var address: String {
        let value = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("://") else { return value }
        return selectedProtocol.rawValue + "://" + value
    }

    func focusAddressField() {
        window?.makeFirstResponder(addressField)
    }

    private var selectedProtocol: ServerProtocolOption {
        let index = protocolPopup.indexOfSelectedItem
        return ServerProtocolOption.allCases.indices.contains(index)
            ? ServerProtocolOption.allCases[index]
            : .smb
    }

    @objc private func protocolChanged(_ sender: Any?) {
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        addressField.placeholderString = selectedProtocol.rawValue + "://" + selectedProtocol.example
    }

    private static func parse(_ address: String?) -> (scheme: String?, remainder: String) {
        guard let address, !address.isEmpty else { return (nil, "") }
        guard let separator = address.range(of: "://") else { return (nil, address) }
        return (
            String(address[..<separator.lowerBound]),
            String(address[separator.upperBound...])
        )
    }
}
