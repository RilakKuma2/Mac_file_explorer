import Darwin
import Foundation

/// Identity of the directory entry itself, including dangling symbolic links.
struct FileEntryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(at url: URL) {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { return nil }
        device = value.st_dev
        inode = value.st_ino
    }
}

struct FileRecoveryError: LocalizedError {
    let underlyingError: Error
    let preservedURLs: [URL]

    var errorDescription: String? {
        L10n.text("The operation could not be fully rolled back. Files were preserved at:") + "\n"
            + preservedURLs.map(\.path).joined(separator: "\n")
            + "\n" + underlyingError.localizedDescription
    }
}
