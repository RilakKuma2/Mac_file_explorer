import AppKit

/// A filesystem entry participating in a file-list drag.
///
/// Directory-ness is supplied by the caller so the decision itself stays
/// deterministic and never touches the filesystem. That also makes validation
/// and acceptance use exactly the same rules.
struct FileDropSource: Equatable {
    let url: URL
    let isDirectory: Bool
}

enum FileDropTarget: Equatable {
    case background(URL)
    case folder(URL, isPackage: Bool)
}

enum FileDropOrigin: Equatable {
    case internalDrag
    case externalDrag
}

struct FileDropDecision: Equatable {
    let destination: URL?
    let operation: NSDragOperation

    static let rejected = FileDropDecision(destination: nil, operation: [])

    var isAccepted: Bool {
        destination != nil && !operation.isEmpty
    }

    var shouldMove: Bool {
        operation == .move
    }
}

/// Shared drag/drop policy for both details and icon views.
///
/// The policy intentionally defaults drags from outside MacExplorer to copy, while
/// moving drags that originate in MacExplorer. Holding Option explicitly requests a
/// copy for an internal drag. Unsafe recursive directory drops are rejected
/// before either view advertises an operation to AppKit.
enum FileDropPolicy {
    static func decision(
        sources: [FileDropSource],
        target: FileDropTarget,
        origin: FileDropOrigin,
        sourceOperationMask: NSDragOperation,
        copyRequested: Bool
    ) -> FileDropDecision {
        guard !sources.isEmpty else { return .rejected }

        let destination: URL
        switch target {
        case .background(let url):
            destination = url
        case let .folder(url, isPackage):
            guard !isPackage else { return .rejected }
            destination = url
        }

        guard destination.isFileURL,
              sources.allSatisfy({ $0.url.isFileURL }) else { return .rejected }

        if sources.contains(where: {
            $0.isDirectory && isSameAsOrDescendant(destination, of: $0.url)
        }) {
            return .rejected
        }

        let operation: NSDragOperation
        switch origin {
        case .externalDrag:
            // Moving data out of another app is surprising and can delete the
            // source. External drops therefore use the Explorer-style safe
            // default: copy.
            operation = .copy
        case .internalDrag:
            if copyRequested {
                operation = .copy
            } else if sourceOperationMask.contains(.move) {
                operation = .move
            } else {
                operation = .copy
            }
        }

        guard sourceOperationMask.contains(operation) else { return .rejected }
        return FileDropDecision(destination: destination, operation: operation)
    }

    private static func isSameAsOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryComponents = normalizedPathComponents(of: directory)
        let candidateComponents = normalizedPathComponents(of: candidate)
        guard candidateComponents.count >= directoryComponents.count else { return false }
        return zip(directoryComponents, candidateComponents).allSatisfy { $0.0 == $0.1 }
    }

    private static func normalizedPathComponents(of url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map(\.precomposedStringWithCanonicalMapping)
    }
}
