import AppKit
import Testing
@testable import MacExplorer

@Suite("Keyboard shortcuts")
struct KeyboardShortcutTests {
    @Test("Bindings preserve key codes and normalized modifiers")
    func bindingRoundTrip() {
        let original = ShortcutBinding(keyCode: 117, modifiers: [.command, .shift, .capsLock])
        let decoded = ShortcutBinding(encoded: original.encoded)
        #expect(decoded == ShortcutBinding(keyCode: 117, modifiers: [.command, .shift]))
        #expect(decoded?.displayString == "⇧⌘⌦")
    }

    @Test("Keypad zoom keys match their main keyboard equivalents")
    func keypadZoomAliases() throws {
        let keypadPlus = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "+",
            isARepeat: false,
            keyCode: 69
        ))
        let keypadMinus = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "-",
            charactersIgnoringModifiers: "-",
            isARepeat: false,
            keyCode: 78
        ))

        #expect(ShortcutBinding(keyCode: 24, modifiers: [.command, .shift]).matches(keypadPlus))
        #expect(ShortcutBinding(keyCode: 27, modifiers: .command).matches(keypadMinus))
    }

    @Test("Zoom-in accepts the unshifted equals form synthesized by mouse utilities")
    func equalsZoomAlias() throws {
        let commandEquals = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "=",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        ))

        #expect(ShortcutBinding(keyCode: 24, modifiers: [.command, .shift]).matches(commandEquals))
        #expect(ShortcutBinding(keyCode: 24, modifiers: [.command, .shift])
            .isEquivalentForMatching(to: ShortcutBinding(keyCode: 24, modifiers: .command)))
    }

    @Test("Reopen-tab and tab-bar shortcuts do not conflict")
    func tabShortcutDefaults() {
        #expect(ExplorerTabShortcutDefaults.reopenClosedTab == ShortcutBinding(
            keyCode: 17,
            modifiers: [.command, .shift]
        ))
        #expect(ExplorerTabShortcutDefaults.reopenClosedTabWindowsAlias == ShortcutBinding(
            keyCode: 17,
            modifiers: [.control, .shift]
        ))
        #expect(ExplorerTabShortcutDefaults.toggleTabBar == ShortcutBinding(
            keyCode: 17,
            modifiers: [.command, .option]
        ))
        #expect(ExplorerTabShortcutDefaults.reopenClosedTab != ExplorerTabShortcutDefaults.toggleTabBar)
    }

    @Test("Common archive formats appear before specialist formats")
    func archiveFormatOrdering() {
        #expect(Array(ArchiveCreationFormat.allCases.prefix(6)) == [
            .zip, .sevenZip, .tarGzip, .tarZstd, .tar, .iso
        ])
        #expect(ArchiveCreationFormat.tarGzip.title == "GZ")
        #expect(ArchiveCreationFormat.tarZstd.title == "ZST")
        #expect(ArchiveCreationFormat.tarGzip.filenameSuffix == ".tar.gz")
    }
}
