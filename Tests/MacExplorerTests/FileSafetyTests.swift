import Foundation
import Testing
@testable import MacExplorer

private final class FailingMoveManager: FileManager, @unchecked Sendable {
    var failures = Set<Int>()
    var calls = 0
    var destinations: [URL] = []
    override func moveItem(at source: URL, to destination: URL) throws {
        calls += 1
        if failures.contains(calls) { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
        destinations.append(destination)
    }
}

@Suite("File safety regression tests")
struct FileSafetyTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileSafety-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test("Undo refuses a different file at the pasted path")
    func changedIdentity() throws {
        try withFolder { folder in
            let file = folder.appendingPathComponent("file")
            try Data("original".utf8).write(to: file)
            let state = CreatedItemsHistoryState(urls: [file])
            try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("retained"))
            try Data("replacement".utf8).write(to: file)
            #expect(throws: FileSystemServiceError.self) { try state.undo() }
            #expect(try String(contentsOf: file, encoding: .utf8) == "replacement")
        }
    }

    @Test("Undo and redo preserve dangling symlinks and reject occupied link destinations")
    func danglingLinkHistory() throws {
        try withFolder { folder in
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "absent")
            let state = CreatedItemsHistoryState(urls: [link])
            try state.undo()
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other")
            #expect(throws: FileSystemServiceError.self) { try state.redo() }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "other")
            try FileManager.default.removeItem(at: link)
            try state.redo()
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "absent")
        }
    }

    @Test("Failed undo rollback never deletes the only surviving copy")
    func undoRecovery() throws {
        try withFolder { folder in
            let files = ["one", "two"].map { folder.appendingPathComponent($0) }
            for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
            let manager = FailingMoveManager()
            manager.failures = [2, 3]
            var state: CreatedItemsHistoryState? = CreatedItemsHistoryState(urls: files, fileManager: manager)
            do {
                try state?.undo()
                Issue.record("Expected rollback failure")
            } catch let error as FileRecoveryError {
                state = nil
                #expect(error.preservedURLs.count == 1)
                for url in error.preservedURLs {
                    #expect(try String(contentsOf: url, encoding: .utf8) == "one")
                    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                #expect(try String(contentsOf: files[1], encoding: .utf8) == "two")
            }
        }
    }

    @Test("Failed redo rollback preserves both restored and stashed items")
    func redoRecovery() throws {
        try withFolder { folder in
            let files = ["one", "two"].map { folder.appendingPathComponent($0) }
            for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
            let manager = FailingMoveManager()
            var state: CreatedItemsHistoryState? = CreatedItemsHistoryState(urls: files, fileManager: manager)
            try state?.undo()
            let containers = manager.destinations.map { $0.deletingLastPathComponent() }
            defer { for url in containers { try? FileManager.default.removeItem(at: url) } }
            manager.failures = [4, 5]
            do {
                try state?.redo()
                Issue.record("Expected rollback failure")
            } catch let error as FileRecoveryError {
                state = nil
                let contents = try error.preservedURLs.map { try String(contentsOf: $0, encoding: .utf8) }
                #expect(Set(contents) == Set(["one", "two"]))
            }
        }
    }

    @Test("Cancelled archive replacement leaves the old archive untouched")
    func cancelledArchive() throws {
        try withFolder { folder in
            let target = folder.appendingPathComponent("old.zip")
            try Data("old".utf8).write(to: target)
            var transaction: ArchiveOutputTransaction? = try ArchiveOutputTransaction(destination: target, replacing: true)
            let output = try #require(transaction?.outputURL)
            try Data("incomplete".utf8).write(to: output)
            transaction = nil
            #expect(try String(contentsOf: target, encoding: .utf8) == "old")
            #expect(!FileSystemService.entryExists(at: output))
        }
    }

    @Test("Archive commit rolls back on failure and rejects a concurrent destination")
    func archiveCommitSafety() throws {
        try withFolder { folder in
            let target = folder.appendingPathComponent("old.zip")
            try Data("old".utf8).write(to: target)
            let manager = FailingMoveManager()
            manager.failures = [2]
            let transaction = try ArchiveOutputTransaction(destination: target, replacing: true, fileManager: manager)
            try Data("new".utf8).write(to: transaction.outputURL)
            #expect(throws: (any Error).self) { try transaction.commit() }
            #expect(try String(contentsOf: target, encoding: .utf8) == "old")
            manager.failures = []
            try transaction.commit()
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
            let absent = folder.appendingPathComponent("new.zip")
            let race = try ArchiveOutputTransaction(destination: absent, replacing: false)
            try Data("archive".utf8).write(to: race.outputURL)
            try Data("other writer".utf8).write(to: absent)
            #expect(throws: FileSystemServiceError.self) { try race.commit() }
            #expect(try String(contentsOf: absent, encoding: .utf8) == "other writer")
        }
    }

    @Test("Archive numbering respects dangling links")
    func archiveLinkName() throws {
        try withFolder { folder in
            let target = folder.appendingPathComponent("backup.zip")
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
            #expect(ArchiveService.uniqueDestination(baseName: "backup", format: .zip, in: folder).lastPathComponent == "backup 2.zip")
        }
    }

    @Test("A failed batch rename restores cyclic names in two phases")
    func batchRenameRollback() throws {
        try withFolder { folder in
            let files = ["a", "b", "c"].map { folder.appendingPathComponent($0) }
            for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
            let manager = FailingMoveManager()
            manager.failures = [6] // Three staging moves, two final moves, then fail.
            let service = FileSystemService(fileManager: manager)
            #expect(throws: (any Error).self) {
                try service.batchRename([(files[0], "b"), (files[1], "a"), (files[2], "d")])
            }
            for file in files {
                #expect(try String(contentsOf: file, encoding: .utf8) == file.lastPathComponent)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
        }
    }

    @Test("Batch rename reports surviving paths when rollback also fails")
    func batchRenameRecovery() throws {
        try withFolder { folder in
            let files = ["a", "b", "c"].map { folder.appendingPathComponent($0) }
            for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
            let manager = FailingMoveManager()
            manager.failures = [6, 7]
            let service = FileSystemService(fileManager: manager)
            do {
                _ = try service.batchRename([(files[0], "b"), (files[1], "a"), (files[2], "d")])
                Issue.record("Expected rollback failure")
            } catch let error as FileRecoveryError {
                #expect(error.preservedURLs.count == 2)
                let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .map { try String(contentsOf: $0, encoding: .utf8) }
                #expect(Set(contents) == Set(["a", "b", "c"]))
            }
        }
    }

    @Test("Batch rename rejects duplicated sources before making changes")
    func batchRenameDuplicateSource() throws {
        try withFolder { folder in
            let file = folder.appendingPathComponent("original")
            try Data("original".utf8).write(to: file)
            #expect(throws: FileSystemServiceError.self) {
                try FileSystemService().batchRename([(file, "one"), (file, "two")])
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "original")
            #expect(throws: FileSystemServiceError.self) { try FileSystemService().rename(file, to: "bad\0name") }
        }
    }

    @Test("An archive rollback failure preserves both old and new files")
    func archiveRecovery() throws {
        try withFolder { folder in
            let target = folder.appendingPathComponent("old.zip")
            try Data("old".utf8).write(to: target)
            let manager = FailingMoveManager()
            manager.failures = [2, 3]
            var transaction: ArchiveOutputTransaction? = try ArchiveOutputTransaction(destination: target, replacing: true, fileManager: manager)
            try Data("new".utf8).write(to: #require(transaction?.outputURL))
            do {
                try transaction?.commit()
                Issue.record("Expected rollback failure")
            } catch let error as FileRecoveryError {
                transaction = nil
                let contents = try error.preservedURLs.map { try String(contentsOf: $0, encoding: .utf8) }
                #expect(Set(contents) == Set(["old", "new"]))
                try FileManager.default.removeItem(at: #require(error.preservedURLs.first).deletingLastPathComponent())
            }
        }
    }

    @Test("ZIP and TAR.GZ staging can be committed and extracted intact")
    func realArchiveRoundTrip() throws {
        func run(_ command: ArchiveCommand) throws {
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.currentDirectoryURL = command.currentDirectoryURL
            process.environment = command.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try withFolder { folder in
            let source = folder.appendingPathComponent("한글 file.txt")
            try Data("archive content".utf8).write(to: source)
            for format in [ArchiveCreationFormat.zip, .tarGzip] {
                let destination = folder.appendingPathComponent("archive" + format.filenameSuffix)
                try Data("previous archive".utf8).write(to: destination)
                let transaction = try ArchiveOutputTransaction(destination: destination, replacing: true)
                let command = try #require(ArchiveService.creationCommand(format: format, sources: [source], destination: transaction.outputURL))
                try run(command)
                #expect(try String(contentsOf: destination, encoding: .utf8) == "previous archive")
                try transaction.commit()
                let extracted = folder.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
                try run(ArchiveService.extractionCommand(archive: destination, destination: extracted))
                #expect(try String(contentsOf: extracted.appendingPathComponent(source.lastPathComponent), encoding: .utf8) == "archive content")
            }
        }
    }
}
