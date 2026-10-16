import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var title: String {
        switch self {
        case .system: return L10n.text("System Default")
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
}

enum L10n {
    private static let languageKey = "MacExplorerLanguage"

    static var selectedLanguage: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: languageKey),
                  let language = AppLanguage(rawValue: raw) else { return .system }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
        }
    }

    static func text(_ key: String) -> String {
        let languageCode: String?
        switch selectedLanguage {
        case .system:
            languageCode = Bundle.main.preferredLocalizations.first
        case .english:
            languageCode = "en"
        case .korean:
            languageCode = "ko"
        case .japanese:
            languageCode = "ja"
        case .french:
            languageCode = "fr"
        case .german:
            languageCode = "de"
        case .spanish:
            languageCode = "es"
        case .simplifiedChinese:
            languageCode = "zh-Hans"
        case .traditionalChinese:
            languageCode = "zh-Hant"
        }

        guard let languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
