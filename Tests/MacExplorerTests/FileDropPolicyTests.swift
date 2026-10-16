import AppKit
import Testing
@testable import MacExplorer

@Suite("File drop policy")
struct FileDropPolicyTests {
    private let root = URL(fileURLWithPath: "/Volumes/Test/Workspace", isDirectory: true)

    @Test("Operation matrix keeps cursor feedback and import behavior aligned")
    func operationMatrix() {
        let file = FileDropSource(
            url: root.appendingPathComponent("notes.txt"),
            isDirectory: false
        )
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let supported: NSDragOperation = [.copy, .move]

        let internalMove = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .internalDrag,
            sourceOperationMask: supported,
            copyRequested: false
        )
        #expect(internalMove.operation == .move)
        #expect(internalMove.shouldMove)
        #expect(internalMove.destination == destination)

        let optionCopy = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .internalDrag,
            sourceOperationMask: supported,
            copyRequested: true
        )
        #expect(optionCopy.operation == .copy)
        #expect(!optionCopy.shouldMove)

        let externalCopy = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .externalDrag,
            sourceOperationMask: supported,
            copyRequested: false
        )
        #expect(externalCopy.operation == .copy)
        #expect(!externalCopy.shouldMove)

        let copyOnlyInternal = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .internalDrag,
            sourceOperationMask: .copy,
            copyRequested: false
        )
        #expect(copyOnlyInternal.operation == .copy)

        let moveOnlyExternal = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .externalDrag,
            sourceOperationMask: .move,
            copyRequested: false
        )
        #expect(!moveOnlyExternal.isAccepted)
        #expect(moveOnlyExternal.operation.isEmpty)

        let unsupportedOptionCopy = FileDropPolicy.decision(
            sources: [file],
            target: .background(destination),
            origin: .internalDrag,
            sourceOperationMask: .move,
            copyRequested: true
        )
        #expect(!unsupportedOptionCopy.isAccepted)
    }

    @Test("Packages are never treated as folder targets")
    func packageTargetIsRejected() {
        let source = FileDropSource(
            url: root.appendingPathComponent("notes.txt"),
            isDirectory: false
        )
        let application = root.appendingPathComponent("Example.app", isDirectory: true)

        let decision = FileDropPolicy.decision(
            sources: [source],
            target: .folder(application, isPackage: true),
            origin: .internalDrag,
            sourceOperationMask: [.copy, .move],
            copyRequested: false
        )

        #expect(!decision.isAccepted)
        #expect(decision.destination == nil)
    }

    @Test("A folder cannot be dropped onto itself or one of its descendants")
    func recursiveFolderDropsAreRejected() {
        let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
        let source = FileDropSource(url: sourceURL, isDirectory: true)
        let masks: NSDragOperation = [.copy, .move]
        let invalidDestinations = [
            sourceURL,
            sourceURL.appendingPathComponent("Child", isDirectory: true),
            sourceURL.appendingPathComponent("Child/Grandchild", isDirectory: true)
        ]

        for destination in invalidDestinations {
            let decision = FileDropPolicy.decision(
                sources: [source],
                target: .background(destination),
                origin: .internalDrag,
                sourceOperationMask: masks,
                copyRequested: false
            )
            #expect(!decision.isAccepted)
        }
    }

    @Test("Path-prefix siblings and files are not mistaken for recursive folder drops")
    func similarPathsRemainValid() {
        let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
        let siblingWithPrefix = root.appendingPathComponent("Source Backup", isDirectory: true)
        let directoryDecision = FileDropPolicy.decision(
            sources: [FileDropSource(url: sourceURL, isDirectory: true)],
            target: .background(siblingWithPrefix),
            origin: .internalDrag,
            sourceOperationMask: [.copy, .move],
            copyRequested: false
        )
        #expect(directoryDecision.operation == .move)

        let fileURL = root.appendingPathComponent("Source.txt")
        let fileDecision = FileDropPolicy.decision(
            sources: [FileDropSource(url: fileURL, isDirectory: false)],
            target: .background(fileURL.appendingPathComponent("Child", isDirectory: true)),
            origin: .internalDrag,
            sourceOperationMask: [.copy, .move],
            copyRequested: false
        )
        #expect(fileDecision.operation == .move)
    }

    @Test("One unsafe folder rejects the entire multi-item drop")
    func mixedUnsafeDropIsRejected() {
        let folderURL = root.appendingPathComponent("Source", isDirectory: true)
        let sources = [
            FileDropSource(url: root.appendingPathComponent("safe.txt"), isDirectory: false),
            FileDropSource(url: folderURL, isDirectory: true)
        ]

        let decision = FileDropPolicy.decision(
            sources: sources,
            target: .background(folderURL.appendingPathComponent("Child", isDirectory: true)),
            origin: .externalDrag,
            sourceOperationMask: .copy,
            copyRequested: false
        )

        #expect(!decision.isAccepted)
    }
}
