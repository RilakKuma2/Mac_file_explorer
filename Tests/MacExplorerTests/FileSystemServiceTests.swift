import Foundation
import Testing
@testable import MacExplorer

@Suite("FileSystemService")
struct FileSystemServiceTests {
    @Test("Dangling symlinks participate in naming and move undo")
    func danglingLinkUndo() throws {
        try withTemporaryDirectory { directory in
            let original = directory.appendingPathComponent("link")
            let moved = directory.appendingPathComponent("moved")
            try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: "missing")
            let service = FileSystemService()
            #expect(service.uniqueDestination(named: "link", in: directory, preservingExtension: false) != original)
            try FileManager.default.moveItem(at: original, to: moved)
            try service.undoMoves([(current: moved, original: original)])
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: original.path) == "missing")
            try service.undoCreatedItems([original])
            #expect(!FileSystemService.entryExists(at: original))
        }
    }

    private let service = FileSystemService()

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("Batched listing preserves file and folder display names")
    func listingPreservesDisplayNames() throws {
        try withTemporaryDirectory { directory in
            try Data().write(to: directory.appendingPathComponent("한글 document.txt"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("Folder with spaces"),
                withIntermediateDirectories: false
            )
            let items = try service.contents(of: directory, showHidden: true)
            #expect(items.count == 2)
            for item in items {
                #expect(item.name == FileManager.default.displayName(atPath: item.url.path))
            }
        }
    }

    @Test("Creating folders avoids name collisions")
    func createFolderChoosesUniqueName() throws {
        try withTemporaryDirectory { directory in
            let first = try service.createFolder(in: directory, preferredName: "Folder")
            let second = try service.createFolder(in: directory, preferredName: "Folder")

            #expect(first.lastPathComponent == "Folder")
            #expect(second.lastPathComponent == "Folder 2")
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))
        }
    }

    @Test("Creating text documents avoids name collisions")
    func createTextDocumentChoosesUniqueName() throws {
        try withTemporaryDirectory { directory in
            let first = try service.createEmptyFile(in: directory, preferredName: "Notes.txt")
            let second = try service.createEmptyFile(in: directory, preferredName: "Notes.txt")

            #expect(first.lastPathComponent == "Notes.txt")
            #expect(second.lastPathComponent == "Notes 2.txt")
            #expect((try Data(contentsOf: first)).isEmpty)
            #expect((try Data(contentsOf: second)).isEmpty)
        }
    }

    @Test("Rename rejects path separators")
    func renameRejectsPathSeparators() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("Original")
            try Data().write(to: source)

            #expect(throws: (any Error).self) {
                try service.rename(source, to: "nested/name")
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("Duplicate preserves the filename extension")
    func duplicatePreservesExtension() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: source)

            let duplicate = try service.duplicate(source)

            #expect(duplicate.lastPathComponent == "notes copy.txt")
            #expect(try String(contentsOf: duplicate, encoding: .utf8) == "hello")
        }
    }

    @Test("Copy does not overwrite an existing file")
    func copyAvoidsOverwritingExistingFile() throws {
        try withTemporaryDirectory { directory in
            let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
            let destinationDirectory = directory.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            let source = sourceDirectory.appendingPathComponent("report.txt")
            try Data("new".utf8).write(to: source)
            try Data("old".utf8).write(to: destinationDirectory.appendingPathComponent("report.txt"))

            try service.copy([source], to: destinationDirectory)

            #expect(
                try String(contentsOf: destinationDirectory.appendingPathComponent("report 2.txt"), encoding: .utf8) == "new"
            )
        }
    }

    @Test("Moving inside the same folder is a no-op")
    func moveWithinSameFolderDoesNotRenameItem() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("stay.txt")
            try Data("content".utf8).write(to: source)

            try service.move([source], to: directory)

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stay 2.txt").path))
        }
    }

    @Test("A direct listing inherits the directory volume locality")
    func directListingUsesDirectoryVolumeLocality() throws {
        try withTemporaryDirectory { directory in
            try Data("content".utf8).write(to: directory.appendingPathComponent("item.txt"))
            let locality = try directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            let expected = try #require(locality as Bool?)

            let items = try service.contents(of: directory, showHidden: true)

            #expect(items.count == 1)
            #expect(items[0].isOnLocalVolume == expected)
        }
    }

    @Test("Undo helpers remove created items and restore moves")
    func undoFileOperations() throws {
        try withTemporaryDirectory { directory in
            let originalDirectory = directory.appendingPathComponent("original", isDirectory: true)
            let destinationDirectory = directory.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            let original = originalDirectory.appendingPathComponent("notes.txt")
            let moved = destinationDirectory.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: original)
            try FileManager.default.moveItem(at: original, to: moved)
            try service.undoMoves([(current: moved, original: original)])
            #expect(FileManager.default.fileExists(atPath: original.path))
            #expect(!FileManager.default.fileExists(atPath: moved.path))

            let created = try service.duplicate(original)
            try service.undoCreatedItems([created])
            #expect(!FileManager.default.fileExists(atPath: created.path))
        }
    }

    @Test("Search includes matching items in child folders")
    func recursiveSearchFindsNestedItems() throws {
        try withTemporaryDirectory { directory in
            let child = directory.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("nested".utf8).write(to: child.appendingPathComponent("quarterly report.txt"))
            try Data("other".utf8).write(to: directory.appendingPathComponent("notes.txt"))

            let results = service.search(in: directory, query: "report", showHidden: false)

            #expect(results.map(\.url.lastPathComponent) == ["quarterly report.txt"])
        }
    }

    @Test("Recursive search stops promptly when cancelled")
    func recursiveSearchCancellation() throws {
        try withTemporaryDirectory { directory in
            for index in 0..<100 {
                try Data().write(to: directory.appendingPathComponent("item-\(index).txt"))
            }
            var continuationChecks = 0

            let results = service.search(
                in: directory,
                query: "item",
                showHidden: false,
                shouldContinue: {
                    continuationChecks += 1
                    return continuationChecks < 5
                }
            )

            #expect(continuationChecks == 5)
            #expect(results.count < 100)
        }
    }
}
