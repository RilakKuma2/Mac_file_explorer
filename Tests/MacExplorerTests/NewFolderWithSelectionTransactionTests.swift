import Foundation
import Testing
@testable import MacExplorer

@Suite("New Folder with Selection transaction")
struct NewFolderWithSelectionTransactionTests {
    private enum InjectedError: Error {
        case failedMove
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerFolderSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("One undo restores every item and redo recreates the exact folder")
    func undoAndRedoWholeTransaction() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("Document.txt")
            let project = root.appendingPathComponent("Project", isDirectory: true)
            try Data("document".utf8).write(to: document)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: project.appendingPathComponent("Nested.txt"))
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [document, project]
            )

            let result = try transaction.perform()

            #expect(result.folderURL.path == root.appendingPathComponent("Collected Items", isDirectory: true).path)
            #expect(result.movedURLs.map(\.lastPathComponent) == ["Document.txt", "Project"])
            #expect(!FileManager.default.fileExists(atPath: document.path))
            #expect(!FileManager.default.fileExists(atPath: project.path))
            #expect(try String(contentsOf: result.movedURLs[0], encoding: .utf8) == "document")
            #expect(try String(
                contentsOf: result.movedURLs[1].appendingPathComponent("Nested.txt"),
                encoding: .utf8
            ) == "nested")

            try transaction.undo()

            #expect(FileManager.default.fileExists(atPath: document.path))
            #expect(FileManager.default.fileExists(atPath: project.path))
            #expect(!FileManager.default.fileExists(atPath: result.folderURL.path))

            try transaction.redo()

            #expect(FileManager.default.fileExists(atPath: result.folderURL.path))
            #expect(!FileManager.default.fileExists(atPath: document.path))
            #expect(!FileManager.default.fileExists(atPath: project.path))
            #expect(try String(contentsOf: result.movedURLs[0], encoding: .utf8) == "document")
        }
    }

    @Test("A partial initial failure restores all items and removes the empty folder")
    func initialFailureRollsBack() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First.txt")
            let second = root.appendingPathComponent("Second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [first, second],
                moveHook: { phase, index, _, _ in
                    if phase == .apply, index == 1 { throw InjectedError.failedMove }
                }
            )

            #expect(throws: InjectedError.self) {
                try transaction.perform()
            }
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Collected Items", isDirectory: true).path
            ))
        }
    }

    @Test("A partial undo failure restores the fully applied state and can be retried")
    func undoFailureRollsForward() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First.txt")
            let second = root.appendingPathComponent("Second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            var injectUndoFailure = true
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [first, second],
                moveHook: { phase, index, _, _ in
                    if phase == .undo, index == 1, injectUndoFailure {
                        injectUndoFailure = false
                        throw InjectedError.failedMove
                    }
                }
            )
            let result = try transaction.perform()

            #expect(throws: InjectedError.self) {
                try transaction.undo()
            }
            #expect(FileManager.default.fileExists(atPath: result.movedURLs[0].path))
            #expect(FileManager.default.fileExists(atPath: result.movedURLs[1].path))
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: second.path))

            try transaction.undo()
            #expect(!FileManager.default.fileExists(atPath: result.folderURL.path))
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))
        }
    }

    @Test("A partial redo failure restores the fully undone state and can be retried")
    func redoFailureRollsBack() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First.txt")
            let second = root.appendingPathComponent("Second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            var injectRedoFailure = true
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [first, second],
                moveHook: { phase, index, _, _ in
                    if phase == .redo, index == 1, injectRedoFailure {
                        injectRedoFailure = false
                        throw InjectedError.failedMove
                    }
                }
            )
            let result = try transaction.perform()
            try transaction.undo()

            #expect(throws: InjectedError.self) {
                try transaction.redo()
            }
            #expect(!FileManager.default.fileExists(atPath: result.folderURL.path))
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))

            try transaction.redo()
            #expect(FileManager.default.fileExists(atPath: result.folderURL.path))
            #expect(FileManager.default.fileExists(atPath: result.movedURLs[0].path))
            #expect(FileManager.default.fileExists(atPath: result.movedURLs[1].path))
        }
    }

    @Test("Undo never deletes an item added to the created folder later")
    func undoRejectsChangedFolderContents() throws {
        try withTemporaryDirectory { root in
            let selected = root.appendingPathComponent("Selected.txt")
            try Data("selected".utf8).write(to: selected)
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [selected]
            )
            let result = try transaction.perform()
            let extra = result.folderURL.appendingPathComponent("Added Later.txt")
            try Data("keep me".utf8).write(to: extra)

            #expect(throws: NewFolderWithSelectionTransactionError.self) {
                try transaction.undo()
            }
            #expect(try String(contentsOf: extra, encoding: .utf8) == "keep me")
            #expect(FileManager.default.fileExists(atPath: result.movedURLs[0].path))
            #expect(!FileManager.default.fileExists(atPath: selected.path))
        }
    }

    @Test("Redo does not overwrite a folder that took the original name")
    func redoPreservesConflictingFolder() throws {
        try withTemporaryDirectory { root in
            let selected = root.appendingPathComponent("Selected.txt")
            try Data("selected".utf8).write(to: selected)
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [selected]
            )
            let result = try transaction.perform()
            try transaction.undo()
            try FileManager.default.createDirectory(at: result.folderURL, withIntermediateDirectories: false)
            let conflictingItem = result.folderURL.appendingPathComponent("Do Not Delete.txt")
            try Data("keep me".utf8).write(to: conflictingItem)

            #expect(throws: FileSystemServiceError.self) {
                try transaction.redo()
            }
            #expect(try String(contentsOf: selected, encoding: .utf8) == "selected")
            #expect(try String(contentsOf: conflictingItem, encoding: .utf8) == "keep me")
        }
    }

    @Test("Undo rejects a different folder that replaced the created folder")
    func undoPreservesReplacementFolderIdentity() throws {
        try withTemporaryDirectory { root in
            let selected = root.appendingPathComponent("Selected.txt")
            try Data("selected".utf8).write(to: selected)
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: root,
                preferredName: "Collected Items",
                selectedURLs: [selected]
            )
            let result = try transaction.perform()
            let parkedFolder = root.appendingPathComponent("Original Collected Items", isDirectory: true)
            try FileManager.default.moveItem(at: result.folderURL, to: parkedFolder)
            try FileManager.default.createDirectory(at: result.folderURL, withIntermediateDirectories: false)
            let replacementItem = result.folderURL.appendingPathComponent("Selected.txt")
            try Data("replacement".utf8).write(to: replacementItem)

            #expect(throws: NewFolderWithSelectionTransactionError.self) {
                try transaction.undo()
            }
            #expect(try String(contentsOf: replacementItem, encoding: .utf8) == "replacement")
            #expect(try String(
                contentsOf: parkedFolder.appendingPathComponent("Selected.txt"),
                encoding: .utf8
            ) == "selected")
            #expect(!FileManager.default.fileExists(atPath: selected.path))
        }
    }
}
