import AppKit

enum ExplorerTabShortcutDefaults {
    static let reopenClosedTab = ShortcutBinding(keyCode: 17, modifiers: [.command, .shift])
    static let reopenClosedTabWindowsAlias = ShortcutBinding(keyCode: 17, modifiers: [.control, .shift])
    static let toggleTabBar = ShortcutBinding(keyCode: 17, modifiers: [.command, .option])
}

struct ShortcutBinding: Hashable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift
    ]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func == (lhs: ShortcutBinding, rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    var encoded: String { "\(keyCode):\(modifiers.rawValue)" }

    init?(encoded: String) {
        let pieces = encoded.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2,
              let keyCode = UInt16(pieces[0]),
              let rawModifiers = UInt(pieces[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: rawModifiers))
    }

    func matches(_ event: NSEvent) -> Bool {
        let eventBinding = ShortcutBinding(event: event)
        return isEquivalentForMatching(to: eventBinding)
    }

    func isEquivalentForMatching(to other: ShortcutBinding) -> Bool {
        normalizedForMatching == other.normalizedForMatching
    }

    private var normalizedForMatching: ShortcutBinding {
        switch keyCode {
        case 69: // Numeric keypad +, emitted by mouse utilities such as LinearMouse.
            return ShortcutBinding(keyCode: 24, modifiers: modifiers.union(.shift)).normalizedForMatching
        case 78: // Numeric keypad -.
            return ShortcutBinding(keyCode: 27, modifiers: modifiers)
        case 24 where modifiers.contains(.command):
            // '+' and '=' share the same physical key. Mouse utilities do not
            // consistently synthesize Shift, so treat both forms as the same
            // zoom shortcut when Command is held. Control-Plus remains distinct
            // because Windows Explorer reserves its keypad form for column fit.
            return ShortcutBinding(keyCode: 24, modifiers: modifiers.subtracting(.shift))
        default:
            return self
        }
    }

    var displayString: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + Self.keyName(for: keyCode)
    }

    var menuKeyEquivalent: String? {
        Self.keyEquivalent(for: keyCode)
    }

    static func fromMenuItem(_ item: NSMenuItem) -> ShortcutBinding? {
        guard !item.keyEquivalent.isEmpty,
              let keyCode = keyCode(forKeyEquivalent: item.keyEquivalent) else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        if item.keyEquivalent == "+" { modifiers.insert(.shift) }
        return ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
    }

    private static func keyName(for keyCode: UInt16) -> String {
        if let name = keyNames[keyCode] { return name }
        return String(format: L10n.text("Key %d"), keyCode)
    }

    private static func keyEquivalent(for keyCode: UInt16) -> String? {
        if let character = keyEquivalentCharacters[keyCode] { return character }
        return functionKeyEquivalent(for: keyCode)
    }

    private static func keyCode(forKeyEquivalent equivalent: String) -> UInt16? {
        if equivalent == "+" { return 24 }
        if let result = keyEquivalentCharacters.first(where: { $0.value == equivalent.lowercased() })?.key {
            return result
        }
        if equivalent == "↑" { return 126 }
        if equivalent == "↓" { return 125 }
        if equivalent == "←" { return 123 }
        if equivalent == "→" { return 124 }
        return functionKeyCodes.first(where: { scalarString($0.value) == equivalent })?.key
    }

    private static func functionKeyEquivalent(for keyCode: UInt16) -> String? {
        functionKeyCodes[keyCode].map(scalarString)
    }

    private static func scalarString(_ value: Int) -> String {
        UnicodeScalar(value).map(String.init) ?? ""
    }

    private static let keyEquivalentCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "\r",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "n", 46: "m", 47: ".", 48: "\t", 49: " ", 50: "`",
        51: "\u{8}", 53: "\u{1b}", 76: "\r"
    ]

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: L10n.text("Space"),
        50: "`", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦", 123: "←", 124: "→",
        69: "Num +", 78: "Num −", 125: "↓", 126: "↑", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1"
    ]

    private static let functionKeyCodes: [UInt16: Int] = [
        96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey,
        99: NSF3FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey,
        103: NSF11FunctionKey, 105: NSF13FunctionKey, 107: NSF14FunctionKey,
        109: NSF10FunctionKey, 111: NSF12FunctionKey, 113: NSF15FunctionKey,
        117: NSDeleteFunctionKey, 118: NSF4FunctionKey, 120: NSF2FunctionKey,
        122: NSF1FunctionKey, 123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
        125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey
    ]
}

final class ShortcutDefinition {
    let id: String
    let title: String
    let category: String
    let macOSDefault: ShortcutBinding?
    let windowsDefault: ShortcutBinding?
    let allowsWhileEditingText: Bool
    var isHandledByMenu: Bool
    var handler: (() -> Bool)?
    weak var menuItem: NSMenuItem?

    init(
        id: String,
        title: String,
        category: String,
        macOSDefault: ShortcutBinding?,
        windowsDefault: ShortcutBinding?,
        allowsWhileEditingText: Bool = false,
        isHandledByMenu: Bool = false,
        menuItem: NSMenuItem? = nil,
        handler: (() -> Bool)? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.macOSDefault = macOSDefault
        self.windowsDefault = windowsDefault
        self.allowsWhileEditingText = allowsWhileEditingText
        self.isHandledByMenu = isHandledByMenu
        self.menuItem = menuItem
        self.handler = handler
    }

    func defaultBinding(for profile: ShortcutProfile) -> ShortcutBinding? {
        profile == .macOS ? macOSDefault : windowsDefault
    }
}

extension Notification.Name {
    static let explorerShortcutsDidChange = Notification.Name("ExplorerShortcutsDidChange")
}

final class ShortcutRegistry {
    static let shared = ShortcutRegistry()

    private static let overridesKey = "ExplorerShortcutOverrides"
    private(set) var definitions: [ShortcutDefinition] = []

    private init() {}

    func resetDefinitions() {
        definitions.removeAll()
    }

    func register(_ definition: ShortcutDefinition) {
        guard !definitions.contains(where: { $0.id == definition.id }) else { return }
        definitions.append(definition)
        applyBindingToMenuItem(definition)
    }

    func registerMenuShortcuts(in mainMenu: NSMenu) {
        var selectorOccurrences: [String: Int] = [:]
        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu else { continue }
            let category = submenu.title.isEmpty ? L10n.text("Application") : submenu.title
            for item in submenu.items where item.action != nil && !item.keyEquivalent.isEmpty {
                let selectorName = NSStringFromSelector(item.action!)
                let occurrence = selectorOccurrences[selectorName, default: 0]
                selectorOccurrences[selectorName] = occurrence + 1
                let id = "menu.\(selectorName).\(occurrence)"
                register(ShortcutDefinition(
                    id: id,
                    title: item.title,
                    category: category,
                    macOSDefault: ShortcutBinding.fromMenuItem(item),
                    windowsDefault: ShortcutBinding.fromMenuItem(item),
                    allowsWhileEditingText: ["cutProxy:", "copyProxy:", "pasteProxy:"].contains(selectorName),
                    isHandledByMenu: true,
                    menuItem: item
                ))
            }
        }
    }

    func routeMenuShortcut(action: Selector, through handler: @escaping () -> Bool) {
        for definition in definitions where definition.menuItem?.action == action {
            definition.isHandledByMenu = false
            definition.handler = handler
        }
    }

    func binding(for definition: ShortcutDefinition) -> ShortcutBinding? {
        let overrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        if let encoded = overrides[definition.id] {
            return encoded == "none" ? nil : ShortcutBinding(encoded: encoded)
        }
        return definition.defaultBinding(for: ShortcutProfile.current)
    }

    func setBinding(_ binding: ShortcutBinding?, for definition: ShortcutDefinition) {
        var overrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        overrides[definition.id] = binding?.encoded ?? "none"
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        applyBindingToMenuItem(definition)
        NotificationCenter.default.post(name: .explorerShortcutsDidChange, object: definition.id)
    }

    func resetBinding(for definition: ShortcutDefinition) {
        var overrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        overrides.removeValue(forKey: definition.id)
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        applyBindingToMenuItem(definition)
        NotificationCenter.default.post(name: .explorerShortcutsDidChange, object: definition.id)
    }

    func applyPreset(_ profile: ShortcutProfile) {
        ShortcutProfile.current = profile
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
        refreshMenuItems()
        NotificationCenter.default.post(name: .explorerShortcutsDidChange, object: nil)
    }

    func conflicts(for binding: ShortcutBinding, excluding definition: ShortcutDefinition) -> [ShortcutDefinition] {
        definitions.filter { candidate in
            guard candidate.id != definition.id,
                  let candidateBinding = self.binding(for: candidate) else { return false }
            return candidateBinding.isEquivalentForMatching(to: binding)
        }
    }

    func handleNonMenuShortcut(event: NSEvent, isEditingText: Bool) -> Bool {
        for definition in definitions where !definition.isHandledByMenu {
            guard let binding = binding(for: definition), binding.matches(event) else { continue }
            if isEditingText && !definition.allowsWhileEditingText { continue }
            if definition.handler?() == true { return true }
        }
        return false
    }

    func refreshMenuItems() {
        for definition in definitions { applyBindingToMenuItem(definition) }
    }

    private func applyBindingToMenuItem(_ definition: ShortcutDefinition) {
        guard let item = definition.menuItem else { return }
        guard let binding = binding(for: definition), let equivalent = binding.menuKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = binding.modifiers
    }
}

final class ShortcutRecorderButton: NSButton {
    var binding: ShortcutBinding? {
        didSet { updateTitle() }
    }
    var onRecord: ((ShortcutBinding) -> Void)?
    private var eventMonitor: Any?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording(_:))
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { stopRecording() }

    @objc private func beginRecording(_ sender: Any?) {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        title = L10n.text("Press shortcut") + "…"
        contentTintColor = .controlAccentColor
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, modifiers.isEmpty {
                self.stopRecording()
                return nil
            }
            let binding = ShortcutBinding(event: event)
            self.stopRecording()
            self.onRecord?(binding)
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isRecording = false
        contentTintColor = nil
        updateTitle()
    }

    private func updateTitle() {
        guard !isRecording else { return }
        title = binding?.displayString ?? L10n.text("Not assigned")
    }
}
