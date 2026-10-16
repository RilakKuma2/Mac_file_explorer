import AppKit

enum FileRenameWarning {
    static func makeAlert(for url: URL, proposedName: String, isDirectory: Bool) -> NSAlert? {
        guard !isDirectory,
              url.pathExtension.lowercased() != (proposedName as NSString).pathExtension.lowercased() else { return nil }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Change the file extension?")
        alert.informativeText = String(format: L10n.text("Changing the extension may make the file open in a different app or stop opening correctly. Use the new name ‘%@’ ?"), proposedName)
        alert.addButton(withTitle: L10n.text("Change Extension")).keyEquivalent = "\r"
        alert.addButton(withTitle: L10n.text("Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }
}
