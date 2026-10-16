import Foundation

/// Build away from the requested name. Cancellation never deletes an existing archive.
final class ArchiveOutputTransaction {
    let outputURL: URL
    private let destination: URL
    private let container: URL
    private let originalIdentity: FileEntryIdentity?
    private let manager: FileManager
    private var preserveForRecovery = false

    init(destination: URL, replacing: Bool, fileManager: FileManager = .default) throws {
        self.destination = destination
        manager = fileManager
        originalIdentity = FileEntryIdentity(at: destination)
        if originalIdentity != nil && !replacing { throw FileSystemServiceError.nameConflict }
        if let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true {
            throw FileSystemServiceError.nameConflict
        }
        container = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: destination, create: true)
        outputURL = container.appendingPathComponent(destination.lastPathComponent)
    }

    func commit() throws {
        guard FileEntryIdentity(at: destination) == originalIdentity else {
            throw FileSystemServiceError.nameConflict
        }
        guard FileSystemService.entryExists(at: outputURL) else { throw CocoaError(.fileNoSuchFile) }
        let backup = container.appendingPathComponent("previous-" + UUID().uuidString)
        if originalIdentity != nil { try manager.moveItem(at: destination, to: backup) }
        do {
            try manager.moveItem(at: outputURL, to: destination)
        } catch {
            if originalIdentity != nil {
                do { try manager.moveItem(at: backup, to: destination) }
                catch {
                    preserveForRecovery = true
                    throw FileRecoveryError(underlyingError: error, preservedURLs: [backup, outputURL])
                }
            }
            throw error
        }
        try? manager.removeItem(at: container)
    }

    deinit {
        if !preserveForRecovery { try? manager.removeItem(at: container) }
    }
}
