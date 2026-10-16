import Foundation

enum BrowserLocation: Equatable {
    case home
    case recents
    case network
    case tag(FinderTag)
    case folder(URL)

    var folderURL: URL? {
        guard case let .folder(url) = self else { return nil }
        return url
    }

    var title: String {
        switch self {
        case .home:
            return L10n.text("Home")
        case .recents:
            return L10n.text("Recent")
        case .network:
            return L10n.text("Network")
        case let .tag(tag):
            return tag.name
        case let .folder(url):
            if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
               url.standardizedFileURL == desktop.standardizedFileURL {
                return L10n.text("Desktop")
            }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.isEmpty ? url.path : name
        }
    }

    /// A stable, unambiguous address suitable for tooltips and direct entry.
    /// Virtual locations use the same scheme understood by the breadcrumb
    /// address field, while physical locations expose their full filesystem
    /// path instead of only the last component shown in a tab title.
    var addressDescription: String {
        switch self {
        case .home:
            return "home://"
        case .recents:
            return "recent://"
        case .network:
            return "network://"
        case let .tag(tag):
            let encoded = tag.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? tag.name
            return "tag://\(encoded)"
        case let .folder(url):
            return url.standardizedFileURL.path
        }
    }
}
