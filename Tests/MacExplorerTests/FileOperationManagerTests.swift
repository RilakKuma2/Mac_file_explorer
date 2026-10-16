import AppKit
import Foundation
import Testing
@testable import MacExplorer

private final class DestinationRaceFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try Data("concurrent writer".utf8).write(to: dstURL)
        throw CocoaError(.fileWriteFileExists)
    }
}

@Suite("FileTransferTask")
struct FileOperationManagerTests {
    @Test("Moving into the same directory through a symlink is a no-op")
    func moveThroughDirectoryAlias() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("file.txt")
            let alias = destinationDirectory.appendingPathComponent("alias")
            try Data("original".utf8).write(to: source)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sourceDirectory)
            let result = try FileTransferTask(kind: .move, sources: [source], destinationDirectory: alias).run()
            #expect(result.createdURLs == [source])
            #expect(result.completedMoves.isEmpty)
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
            #expect(try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path) == ["file.txt"])
        }
    }

    @Test("A failed atomic move never deletes a concurrently created destination")
    func atomicMoveRacePreservesDestination() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("file.txt")
            try Data("original".utf8).write(to: source)
            let task = FileTransferTask(kind: .move, sources: [source],
                destinationDirectory: destinationDirectory, fileManager: DestinationRaceFileManager())
            #expect(throws: (any Error).self) { try task.run() }
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
            #expect(try String(contentsOf: destinationDirectory.appendingPathComponent("file.txt"),
                               encoding: .utf8) == "concurrent writer")
        }
    }

    @Test("A symlink destination cannot bypass recursive folder protection")
    func rejectSymlinkIntoSource() throws {
        try withDirectories { source, destination in
            let child = source.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            let link = destination.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
            let task = FileTransferTask(kind: .copy, sources: [source], destinationDirectory: link)
            #expect(throws: FileTransferError.self) { try task.run() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
        }
    }

    @Test("Skip preserves a dangling destination symlink")
    func skipDanglingLink() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("file.txt")
            let target = destinationDirectory.appendingPathComponent("file.txt")
            try Data("original".utf8).write(to: source)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
            let result = try FileTransferTask(kind: .copy, sources: [source],
                destinationDirectory: destinationDirectory, conflictPolicy: .skip).run()
            #expect(result.createdURLs.isEmpty)
            #expect(result.remainingSources == [source])
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "missing")
        }
    }

    private func withDirectories(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerTransferTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(source, destination)
    }

    @Test("Copy reports completion and preserves a directory hierarchy")
    func copyWithProgress() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let folder = sourceDirectory.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sourceFile = folder.appendingPathComponent("payload.bin")
            let payload = Data(repeating: 0x5A, count: 1_200_000)
            try payload.write(to: sourceFile)

            let task = FileTransferTask(kind: .copy, sources: [folder], destinationDirectory: destinationDirectory)
            let result = try task.run()
            let results = result.createdURLs

            #expect(results.count == 1)
            #expect(try Data(contentsOf: results[0].appendingPathComponent("payload.bin")) == payload)
            let snapshot = task.snapshot()
            #expect(snapshot.isPrepared)
            #expect(snapshot.completedBytes == snapshot.totalBytes)
            #expect(snapshot.fractionCompleted == 1)
        }
    }

    @Test("Move removes the source and creates the destination")
    func moveWithProgress() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("move-me.txt")
            try Data("move".utf8).write(to: source)

            let task = FileTransferTask(kind: .move, sources: [source], destinationDirectory: destinationDirectory)
            let result = try task.run()
            let results = result.createdURLs

            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(results.count == 1)
            #expect(try String(contentsOf: results[0], encoding: .utf8) == "move")
            #expect(result.completedMoves.count == 1)
            #expect(result.completedMoves[0].source == source)
            #expect(result.completedMoves[0].destination == results[0])
            #expect(task.snapshot().fractionCompleted == 1)
        }
    }

    @Test("A completed cut-and-paste move can be undone using its recorded paths")
    func undoCompletedMove() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("cut-me.txt")
            try Data("move".utf8).write(to: source)
            let task = FileTransferTask(kind: .move, sources: [source], destinationDirectory: destinationDirectory)

            let result = try task.run()
            try FileSystemService().undoMoves(result.completedMoves.map {
                (current: $0.destination, original: $0.source)
            })

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: result.createdURLs[0].path))
            #expect(try String(contentsOf: source, encoding: .utf8) == "move")

            try FileSystemService().undoMoves(result.completedMoves.map {
                (current: $0.source, original: $0.destination)
            })
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: result.createdURLs[0], encoding: .utf8) == "move")
        }
    }

    @Test("Moving and undoing several folders records every destination")
    func undoMultipleMovedFolders() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let sources = try (0..<3).map { index -> URL in
                let folder = sourceDirectory.appendingPathComponent("Folder \(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("\(index)".utf8).write(to: folder.appendingPathComponent("item.txt"))
                return folder
            }
            let task = FileTransferTask(kind: .move, sources: sources, destinationDirectory: destinationDirectory)

            let result = try task.run()
            #expect(result.createdURLs.count == sources.count)
            #expect(result.completedMoves.count == sources.count)
            try FileSystemService().undoMoves(result.completedMoves.map {
                (current: $0.destination, original: $0.source)
            })

            #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            #expect(result.createdURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    @Test("A cancelled transfer stops before changing files")
    func cancelledTransfer() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: source)
            let task = FileTransferTask(kind: .copy, sources: [source], destinationDirectory: destinationDirectory)
            task.cancel()

            #expect(throws: FileTransferError.self) { try task.run() }
            #expect((try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path))?.isEmpty == true)
        }
    }

    @Test("A folder cannot be transferred into its own descendant")
    func rejectsDescendantDestination() throws {
        try withDirectories { sourceDirectory, _ in
            let source = sourceDirectory.appendingPathComponent("Parent", isDirectory: true)
            let child = source.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            let task = FileTransferTask(
                kind: .copy,
                sources: [source],
                destinationDirectory: child
            )

            #expect(throws: FileTransferError.self) { try task.run() }
            #expect(!FileManager.default.fileExists(
                atPath: child.appendingPathComponent("Parent", isDirectory: true).path
            ))
        }
    }

    @Test("Replacing a folder never removes destination-only contents")
    func replacingFolderIsRejectedWithoutDataLoss() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("Project", isDirectory: true)
            let destination = destinationDirectory.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sourceItem = source.appendingPathComponent("from-source.txt")
            let destinationOnlyItem = destination.appendingPathComponent("destination-only.txt")
            try Data("source".utf8).write(to: sourceItem)
            try Data("destination".utf8).write(to: destinationOnlyItem)

            let task = FileTransferTask(
                kind: .copy,
                sources: [source],
                destinationDirectory: destinationDirectory,
                conflictPolicy: .replace
            )

            #expect(throws: FileTransferError.self) { try task.run() }
            #expect(try String(contentsOf: sourceItem, encoding: .utf8) == "source")
            #expect(try String(contentsOf: destinationOnlyItem, encoding: .utf8) == "destination")
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("from-source.txt").path
            ))
        }
    }

    @Test("Moving a replacement folder leaves both folder trees untouched")
    func movingReplacementFolderIsRejectedWithoutDataLoss() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("Project", isDirectory: true)
            let destination = destinationDirectory.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sourceItem = source.appendingPathComponent("from-source.txt")
            let destinationOnlyItem = destination.appendingPathComponent("destination-only.txt")
            try Data("source".utf8).write(to: sourceItem)
            try Data("destination".utf8).write(to: destinationOnlyItem)

            let task = FileTransferTask(
                kind: .move,
                sources: [source],
                destinationDirectory: destinationDirectory,
                conflictPolicy: .replace
            )

            #expect(throws: FileTransferError.self) { try task.run() }
            #expect(try String(contentsOf: sourceItem, encoding: .utf8) == "source")
            #expect(try String(contentsOf: destinationOnlyItem, encoding: .utf8) == "destination")
        }
    }

    @Test("A folder replacement conflict aborts a batch before earlier items change")
    func replacementConflictPreflightsWholeBatch() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let firstSource = sourceDirectory.appendingPathComponent("first.txt")
            try Data("first".utf8).write(to: firstSource)
            let sourceFolder = sourceDirectory.appendingPathComponent("Project", isDirectory: true)
            let destinationFolder = destinationDirectory.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let destinationOnlyItem = destinationFolder.appendingPathComponent("destination-only.txt")
            try Data("destination".utf8).write(to: destinationOnlyItem)

            let task = FileTransferTask(
                kind: .copy,
                sources: [firstSource, sourceFolder],
                destinationDirectory: destinationDirectory,
                conflictPolicy: .replace
            )

            #expect(throws: FileTransferError.self) { try task.run() }
            #expect(!FileManager.default.fileExists(
                atPath: destinationDirectory.appendingPathComponent("first.txt").path
            ))
            #expect(try String(contentsOf: destinationOnlyItem, encoding: .utf8) == "destination")
        }
    }

    @Test("A paused transfer resumes without losing its work")
    func pausedTransferResumes() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let source = sourceDirectory.appendingPathComponent("pause-me.bin")
            let payload = Data(repeating: 0x42, count: 256_000)
            try payload.write(to: source)
            let task = FileTransferTask(kind: .copy, sources: [source], destinationDirectory: destinationDirectory)

            task.pause()
            #expect(task.snapshot().isPaused)
            task.resume()
            #expect(!task.snapshot().isPaused)

            let result = try task.run()
            #expect(try Data(contentsOf: result.createdURLs[0]) == payload)
            #expect(task.snapshot().fractionCompleted == 1)
        }
    }

    @Test("Skipped move sources remain available for another paste")
    func skippedMoveSourcesAreReported() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let skipped = sourceDirectory.appendingPathComponent("existing.txt")
            let moved = sourceDirectory.appendingPathComponent("moved.txt")
            try Data("source".utf8).write(to: skipped)
            try Data("move".utf8).write(to: moved)
            try Data("destination".utf8).write(
                to: destinationDirectory.appendingPathComponent("existing.txt")
            )

            let task = FileTransferTask(
                kind: .move,
                sources: [skipped, moved],
                destinationDirectory: destinationDirectory,
                conflictPolicy: .skip
            )
            let result = try task.run()

            #expect(result.remainingSources == [skipped])
            #expect(FileManager.default.fileExists(atPath: skipped.path))
            #expect(!FileManager.default.fileExists(atPath: moved.path))
            #expect(result.completedMoves.map(\.source) == [moved])
        }
    }

    @Test("A transfer failure reports and preserves completed moves")
    func partialMoveFailureIsRecoverable() throws {
        try withDirectories { sourceDirectory, destinationDirectory in
            let folder = sourceDirectory.appendingPathComponent("Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let child = folder.appendingPathComponent("child.txt")
            try Data("payload".utf8).write(to: child)
            let task = FileTransferTask(
                kind: .move,
                // Moving the parent first makes the second original path vanish
                // after preparation, deterministically exercising partial failure.
                sources: [folder, child],
                destinationDirectory: destinationDirectory
            )

            do {
                _ = try task.run()
                Issue.record("Expected a partial transfer failure")
            } catch let failure as FileTransferPartialFailure {
                #expect(failure.partialResult.createdURLs.count == 1)
                #expect(failure.partialResult.completedMoves.count == 1)
                let moves = failure.partialResult.completedMoves.map {
                    (current: $0.destination, original: $0.source)
                }
                try FileSystemService().undoMoves(moves)
                #expect(try String(contentsOf: child, encoding: .utf8) == "payload")
            }
        }
    }

    @Test("Created items keep their contents across undo and redo")
    func createdItemsUndoRedo() throws {
        try withDirectories { _, destinationDirectory in
            let folder = destinationDirectory.appendingPathComponent("Created Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("payload.txt")
            try Data("preserved".utf8).write(to: file)
            let state = CreatedItemsHistoryState(urls: [folder])

            try state.undo()
            #expect(!FileManager.default.fileExists(atPath: folder.path))

            try state.redo()
            #expect(try String(contentsOf: file, encoding: .utf8) == "preserved")

            try state.undo()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(throws: FileSystemServiceError.self) { try state.redo() }
            try FileManager.default.removeItem(at: folder)
            try state.redo()
            #expect(try String(contentsOf: file, encoding: .utf8) == "preserved")
        }
    }

    @Test("Transfer progress panels do not take focus unless clicked")
    @MainActor
    func progressPanelAvoidsFocusStealing() throws {
        let task = FileTransferTask(
            kind: .copy,
            sources: [URL(fileURLWithPath: "/tmp/source")],
            destinationDirectory: URL(fileURLWithPath: "/tmp")
        )
        let controller = FileOperationProgressWindowController(task: task, parentWindow: nil)
        let panel = try #require(controller.window as? NSPanel)

        #expect(panel.becomesKeyOnlyIfNeeded)
    }
}
