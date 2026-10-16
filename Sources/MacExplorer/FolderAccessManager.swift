import AppKit

final class FolderAccessManager {
    static let shared = FolderAccessManager()

    private let bookmarkKey = "MacExplorerFolderAccessBookmark"
    private var isAccessingResource = false
    private(set) var grantedURL: URL?

    var hasStoredAccess: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    private init() {}

    deinit {
        stopAccessingCurrentResource()
    }

    func restoreAccess() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            beginAccessing(url)
            if isStale { try storeBookmark(for: url) }
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            grantedURL = nil
        }
    }

    func requestAccess(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose a folder to allow access")
        panel.message = L10n.text("Choose your Home folder to let Mac Explorer remember access to its contents.")
        panel.prompt = L10n.text("Allow Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                completion(false)
                return
            }
            do {
                try self.storeBookmark(for: url)
                self.beginAccessing(url)
                completion(true)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                completion(false)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    func clearStoredAccess() {
        stopAccessingCurrentResource()
        grantedURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func beginAccessing(_ url: URL) {
        stopAccessingCurrentResource()
        grantedURL = url.standardizedFileURL
        isAccessingResource = url.startAccessingSecurityScopedResource()
    }

    private func stopAccessingCurrentResource() {
        guard isAccessingResource, let grantedURL else { return }
        grantedURL.stopAccessingSecurityScopedResource()
        isAccessingResource = false
    }
}
