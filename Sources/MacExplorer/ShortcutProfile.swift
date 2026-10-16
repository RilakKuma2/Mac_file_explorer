import Foundation

enum ShortcutProfile: String, CaseIterable {
    case macOS
    case windows

    private static let defaultsKey = "ExplorerShortcutProfile"

    static var current: ShortcutProfile {
        get {
            guard let value = UserDefaults.standard.string(forKey: defaultsKey),
                  let profile = ShortcutProfile(rawValue: value) else { return .macOS }
            return profile
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .macOS: return L10n.text("macOS priority")
        case .windows: return L10n.text("Windows priority")
        }
    }
}
