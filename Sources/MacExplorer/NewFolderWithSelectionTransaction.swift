import Darwin
import Foundation

enum NewFolderWithSelectionTransactionError: LocalizedError {
    case invalidState
    case selectionChanged
    case folderContentsChanged
    case rollbackFailed(operation: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return L10n.text("This file operation can’t be performed in its current state.")
        case .selectionChanged:
            return L10n.text("One or more selected items have moved or no longer exist.")
        case .folderContentsChanged:
            return L10n.text("The new folder has changed since it was created, so it can’t be undone safely.")
        case let .rollbackFailed(operation, rollback):
            return String(
                format: L10n.text("The operation failed and could not be fully rolled back. %@"),
                "\(operation.localizedDescription) \(rollback.localizedDescription)"
            )
        }
    }
}

/// A single undoable filesystem transaction for “New Folder with Selection”.
///
/// All methods are intended to run on FileOperationManager's serialized
/// mutation lane. Every phase journals completed renames and reverses them if a
/// later rename fails. The folder is removed with `rmdir`, never recursive
/// deletion, so an unexpected item can never be destroyed by Undo.
final class NewFolderWithSelectionTransaction {
    private struct FolderIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    enum MovePhase: Equatable {
        case apply
        case applyRollback
        case undo
        case undoRollback
        case redo
        case redoRollback
    }

    struct Result {
        let folderURL: URL
        let movedURLs: [URL]
        let moves: [(current: URL, original: URL)]
    }

    private enum State {
        case ready
        case applied
        case undone
        case invalid
    }

    typealias MoveHook = (_ phase: MovePhase, _ index: Int, _ source: URL, _ destination: URL) throws -> Void

    private let parentDirectory: URL
    private let preferredName: String
    private let originalURLs: [URL]
    private let manager: FileManager
    private let moveHook: MoveHook?
    private var state: State = .ready
    private var completedResult: Result?
    private var appliedFolderIdentity: FolderIdentity?

    init(
        parentDirectory: URL,
        preferredName: String,
        selectedURLs: [URL],
        fileManager: FileManager = .default,
        moveHook: MoveHook? = nil
    ) {
        self.parentDirectory = parentDirectory.standardizedFileURL
        self.preferredName = preferredName
        originalURLs = selectedURLs.map(\.standardizedFileURL)
        manager = fileManager
        self.moveHook = moveHook
    }

    func perform() throws -> Result {
        guard state == .ready else { throw NewFolderWithSelectionTransactionError.invalidState }
        let name = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw FileSystemServiceError.invalidName
        }
        try validateOriginalSelection()

        let folderURL = FileSystemService.shared.uniqueDestination(
            named: name,
            in: parentDirectory,
            preservingExtension: false
        ).standardizedFileURL
        try manager.createDirectory(at: folderURL, withIntermediateDirectories: false)
        guard let folderIdentity = folderIdentity(at: folderURL) else {
            try? removeEmptyDirectory(at: folderURL)
            throw NewFolderWithSelectionTransactionError.invalidState
        }

        let destinationURLs = originalURLs.map {
            folderURL.appendingPathComponent($0.lastPathComponent).standardizedFileURL
        }
        do {
            try moveAll(
                Array(zip(originalURLs, destinationURLs)),
                phase: .apply,
                rollbackPhase: .applyRollback
            )
        } catch {
            do {
                try removeEmptyDirectory(at: folderURL)
            } catch let removalError {
                state = .invalid
                throw NewFolderWithSelectionTransactionError.rollbackFailed(
                    operation: error,
                    rollback: removalError
                )
            }
            throw error
        }

        let result = Result(
            folderURL: folderURL,
            movedURLs: destinationURLs,
            moves: Array(zip(destinationURLs, originalURLs)).map {
                (current: $0.0, original: $0.1)
            }
        )
        completedResult = result
        appliedFolderIdentity = folderIdentity
        state = .applied
        return result
    }

    func undo() throws {
        guard state == .applied, let result = completedResult else {
            throw NewFolderWithSelectionTransactionError.invalidState
        }
        try validateAppliedContents(result)

        let reverseMoves = result.moves.map { (source: $0.current, destination: $0.original) }
        try moveAll(reverseMoves, phase: .undo, rollbackPhase: .undoRollback)
        do {
            try removeEmptyDirectory(at: result.folderURL)
        } catch {
            do {
                try moveAll(
                    result.moves.map { (source: $0.original, destination: $0.current) },
                    phase: .undoRollback,
                    rollbackPhase: .undo
                )
            } catch let rollbackError {
                state = .invalid
                throw NewFolderWithSelectionTransactionError.rollbackFailed(
                    operation: error,
                    rollback: rollbackError
                )
            }
            throw error
        }
        appliedFolderIdentity = nil
        state = .undone
    }

    func redo() throws {
        guard state == .undone, let result = completedResult else {
            throw NewFolderWithSelectionTransactionError.invalidState
        }
        try validateOriginalSelection()
        guard !itemExists(at: result.folderURL) else {
            throw FileSystemServiceError.nameConflict
        }
        try manager.createDirectory(at: result.folderURL, withIntermediateDirectories: false)
        guard let folderIdentity = folderIdentity(at: result.folderURL) else {
            try? removeEmptyDirectory(at: result.folderURL)
            throw NewFolderWithSelectionTransactionError.invalidState
        }

        do {
            try moveAll(
                result.moves.map { (source: $0.original, destination: $0.current) },
                phase: .redo,
                rollbackPhase: .redoRollback
            )
        } catch {
            do {
                try removeEmptyDirectory(at: result.folderURL)
            } catch let removalError {
                state = .invalid
                throw NewFolderWithSelectionTransactionError.rollbackFailed(
                    operation: error,
                    rollback: removalError
                )
            }
            throw error
        }
        appliedFolderIdentity = folderIdentity
        state = .applied
    }

    private func validateOriginalSelection() throws {
        var parentIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parentDirectory.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue,
              !originalURLs.isEmpty,
              Set(originalURLs.map(\.path)).count == originalURLs.count else {
            throw NewFolderWithSelectionTransactionError.selectionChanged
        }
        for original in originalURLs {
            guard original.deletingLastPathComponent().standardizedFileURL == parentDirectory,
                  itemExists(at: original) else {
                throw NewFolderWithSelectionTransactionError.selectionChanged
            }
        }
    }

    private func validateAppliedContents(_ result: Result) throws {
        var folderIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: result.folderURL.path, isDirectory: &folderIsDirectory),
              folderIsDirectory.boolValue,
              let expectedIdentity = appliedFolderIdentity,
              folderIdentity(at: result.folderURL) == expectedIdentity,
              result.moves.allSatisfy({ itemExists(at: $0.current) }),
              result.moves.allSatisfy({ !itemExists(at: $0.original) }) else {
            throw NewFolderWithSelectionTransactionError.folderContentsChanged
        }

        let actualContents = try manager.contentsOfDirectory(
            at: result.folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        let expectedPaths = Set(result.moves.map { $0.current.standardizedFileURL.path })
        guard Set(actualContents.map { $0.standardizedFileURL.path }) == expectedPaths else {
            throw NewFolderWithSelectionTransactionError.folderContentsChanged
        }
    }

    private func moveAll(
        _ moves: [(source: URL, destination: URL)],
        phase: MovePhase,
        rollbackPhase: MovePhase
    ) throws {
        for move in moves {
            guard itemExists(at: move.source), !itemExists(at: move.destination) else {
                throw NewFolderWithSelectionTransactionError.selectionChanged
            }
        }

        var completed: [(source: URL, destination: URL)] = []
        do {
            for (index, move) in moves.enumerated() {
                try moveHook?(phase, index, move.source, move.destination)
                try manager.moveItem(at: move.source, to: move.destination)
                completed.append(move)
            }
        } catch {
            var rollbackError: Error?
            for (index, move) in completed.reversed().enumerated() {
                do {
                    try moveHook?(rollbackPhase, index, move.destination, move.source)
                    try manager.moveItem(at: move.destination, to: move.source)
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackError {
                state = .invalid
                throw NewFolderWithSelectionTransactionError.rollbackFailed(
                    operation: error,
                    rollback: rollbackError
                )
            }
            throw error
        }
    }

    private func removeEmptyDirectory(at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.rmdir(path)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &info) == 0
        }
    }

    private func folderIdentity(at url: URL) -> FolderIdentity? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FolderIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
