import AppKit

enum ServerConnectionError: LocalizedError {
    case invalidAddress
    case unsupportedProtocol
    case couldNotOpen
    case couldNotBrowseNetwork(String?)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return L10n.text("Enter a valid server address.")
        case .unsupportedProtocol:
            return L10n.text("Use an SMB, NFS, WebDAV, HTTP, HTTPS, or FTP server address.")
        case .couldNotOpen:
            return L10n.text("macOS could not open this server address.")
        case let .couldNotBrowseNetwork(details):
            let base = L10n.text("Finder could not open the Network browser.")
            return details.map { base + "\n" + $0 } ?? base
        }
    }
}

final class ServerConnectionManager {
    static let shared = ServerConnectionManager()

    private let savedServersKey = "MacExplorerRecentServers"
    private let supportedSchemes = Set(["smb", "cifs", "nfs", "http", "https", "ftp", "afp"])

    var savedServers: [String] {
        UserDefaults.standard.stringArray(forKey: savedServersKey) ?? []
    }

    private init() {}

    func normalizedAddress(_ rawValue: String) throws -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ServerConnectionError.invalidAddress }
        if !value.contains("://") { value = "smb://" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw ServerConnectionError.invalidAddress
        }
        guard supportedSchemes.contains(scheme) else { throw ServerConnectionError.unsupportedProtocol }
        return value
    }

    @discardableResult
    func connect(to rawValue: String, remember: Bool = true) throws -> URL {
        let address = try normalizedAddress(rawValue)
        guard let url = URL(string: address) else { throw ServerConnectionError.invalidAddress }
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: finderURL, configuration: configuration) { _, _ in }
        } else if !NSWorkspace.shared.open(url) {
            throw ServerConnectionError.couldNotOpen
        }
        if remember { try save(address) }
        return url
    }

    func save(_ rawValue: String) throws {
        let address = try normalizedAddress(rawValue)
        var values = savedServers.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        values.insert(address, at: 0)
        UserDefaults.standard.set(Array(values.prefix(50)), forKey: savedServersKey)
    }

    func replace(_ originalAddress: String, with rawValue: String) throws {
        let address = try normalizedAddress(rawValue)
        var values = savedServers.filter {
            $0.caseInsensitiveCompare(originalAddress) != .orderedSame
                && $0.caseInsensitiveCompare(address) != .orderedSame
        }
        values.insert(address, at: 0)
        UserDefaults.standard.set(Array(values.prefix(50)), forKey: savedServersKey)
    }

    func remove(_ address: String) {
        let values = savedServers.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        UserDefaults.standard.set(values, forKey: savedServersKey)
    }

    func browseNetworkInFinder() throws {
        let localizedNetworkName = finderLocalizedNetworkName()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "com.apple.finder"
            activate
            open folder "\(localizedNetworkName)" of computer container
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw ServerConnectionError.couldNotBrowseNetwork(nil)
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let details = errorInfo[NSAppleScript.errorMessage] as? String
            throw ServerConnectionError.couldNotBrowseNetwork(details)
        }
    }

    private func finderLocalizedNetworkName() -> String {
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"),
              let finderBundle = Bundle(url: finderURL) else { return "Network" }
        let localization = Bundle.preferredLocalizations(
            from: finderBundle.localizations,
            forPreferences: Locale.preferredLanguages
        ).first ?? "en"
        let resources = finderURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let localizationURL = resources.appendingPathComponent(localization + ".lproj", isDirectory: true)
        guard let localizationBundle = Bundle(url: localizationURL) else { return "Network" }
        return localizationBundle.localizedString(forKey: "Network", value: "Network", table: nil)
    }
}
