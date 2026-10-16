import Darwin
import Foundation

enum FileSystemServiceError: LocalizedError {
    case invalidName
    case nameConflict
    case noSelection
    case unsupportedDrop

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return L10n.text("Enter a valid file or folder name.")
        case .nameConflict:
            return L10n.text("Two or more items would have the same name, or a destination name already exists.")
        case .noSelection:
            return L10n.text("Select at least one item first.")
        case .unsupportedDrop:
            return L10n.text("These items cannot be dropped here.")
        }
    }
}

final class FileSystemService {
    /// fileExists follows symlinks and reports dangling links as absent.
    /// Conflict checks and undo operate on the directory entry itself.
    static func entryExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    static let shared = FileSystemService()

    private let manager: FileManager

    init(fileManager: FileManager = .default) { manager = fileManager }

    // Keep the first directory pass limited to metadata needed to render and
    // sort the list. Finder tags are extended attributes and are noticeably
    // slower on large, network, and cloud-backed folders, so they are hydrated
    // after the initial list is visible.
    private let listingResourceKeys: Set<URLResourceKey> = [
        .localizedNameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .localizedTypeDescriptionKey,
        .contentTypeKey
    ]

    private let tagResourceKeys: Set<URLResourceKey> = [
        .tagNamesKey,
        .labelNumberKey
    ]

    private var searchResourceKeys: Set<URLResourceKey> {
        listingResourceKeys.union([.volumeIsLocalKey])
    }

    func contents(of directory: URL, showHidden: Bool, shouldContinue: () -> Bool = { true }) throws -> [FileItem] {
        guard shouldContinue() else { throw CancellationError() }
        if directory.standardizedFileURL == primaryTrashDirectory.standardizedFileURL {
            return try contentsOfTrash(showHidden: showHidden)
        }

        return try contentsOfDirectory(directory, showHidden: showHidden, shouldContinue: shouldContinue)
    }

    var primaryTrashDirectory: URL {
        (try? manager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: manager.homeDirectoryForCurrentUser,
            create: false
        )) ?? manager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    private func contentsOfDirectory(_ directory: URL, showHidden: Bool, shouldContinue: () -> Bool = { true }) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        // Locality is a volume property. Asking for it once per child caused a
        // measurable regression on large, network, and File Provider folders;
        // one directory-level lookup is sufficient for a direct listing.
        let volumeIsLocal = (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(listingResourceKeys),
            options: options
        )

        return try urls.compactMap { url in
            guard shouldContinue() else { throw CancellationError() }
            return item(
                for: url,
                resourceKeys: listingResourceKeys,
                volumeIsLocalOverride: volumeIsLocal
            )
        }
    }

    func loadingTagMetadata(
        for items: [FileItem],
        shouldContinue: () -> Bool = { true }
    ) -> [FileItem]? {
        var taggedItems: [FileItem] = []
        taggedItems.reserveCapacity(items.count)
        for item in items {
            guard shouldContinue() else { return nil }
            if let values = try? item.url.resourceValues(forKeys: tagResourceKeys) {
                taggedItems.append(item.replacingTagMetadata(
                    tagNames: values.tagNames ?? [],
                    labelNumber: values.labelNumber ?? 0
                ))
            } else {
                taggedItems.append(item)
            }
        }
        return taggedItems
    }

    private func contentsOfTrash(showHidden: Bool) throws -> [FileItem] {
        var directories = [primaryTrashDirectory]
        let uid = String(getuid())
        let volumeKeys: [URLResourceKey] = [.volumeIsReadOnlyKey]
        let volumes = manager.mountedVolumeURLs(
            includingResourceValuesForKeys: volumeKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes where volume.path != "/" {
            let candidate = volume
                .appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(uid, isDirectory: true)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.append(candidate)
            }
        }

        var items: [FileItem] = []
        var firstError: Error?
        var successfulDirectoryCount = 0
        var seenPaths = Set<String>()

        for directory in directories {
            do {
                let directoryItems = try contentsOfDirectory(directory, showHidden: showHidden)
                successfulDirectoryCount += 1
                for item in directoryItems where seenPaths.insert(item.url.standardizedFileURL.path).inserted {
                    items.append(item)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if successfulDirectoryCount == 0, let firstError { throw firstError }
        return items
    }

    func search(
        in directory: URL,
        query: String,
        showHidden: Bool,
        limit: Int = 5000,
        shouldContinue: @escaping () -> Bool = { true }
    ) -> [FileItem] {
        let parsedQuery = FileSearchQuery(query)
        guard !parsedQuery.isEmpty, shouldContinue() else { return [] }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(searchResourceKeys),
            options: options,
            errorHandler: { _, _ in shouldContinue() }
        ) else { return [] }

        var results: [FileItem] = []
        for case let url as URL in enumerator {
            if results.count >= limit || !shouldContinue() { break }
            guard let item = item(for: url, resourceKeys: searchResourceKeys) else { continue }
            if parsedQuery.matches(item) {
                results.append(item)
            }
        }
        return results
    }

    @discardableResult
    func createFolder(in directory: URL, preferredName: String = L10n.text("New folder")) throws -> URL {
        let destination = uniqueDestination(named: preferredName, in: directory, preservingExtension: false)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    @discardableResult
    func createEmptyFile(in directory: URL, preferredName: String = L10n.text("New text document.txt")) throws -> URL {
        let destination = uniqueDestination(named: preferredName, in: directory, preservingExtension: true)
        // The destination may have appeared since uniqueDestination checked it.
        try Data().write(to: destination, options: .withoutOverwriting)
        return destination
    }

    @discardableResult
    func rename(_ source: URL, to proposedName: String) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FileSystemServiceError.invalidName
        }

        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != source else { return source }
        try manager.moveItem(at: source, to: destination)
        return destination
    }

    func batchRename(_ changes: [(source: URL, name: String)]) throws -> [URL] {
        guard !changes.isEmpty else { throw FileSystemServiceError.noSelection }
        let prepared = try changes.map { change -> (source: URL, temporary: URL, destination: URL) in
            let name = change.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw FileSystemServiceError.invalidName
            }
            let parent = change.source.deletingLastPathComponent()
            let temporary = uniqueDestination(
                named: ".mac-explorer-rename-\(UUID().uuidString)",
                in: parent,
                preservingExtension: false
            )
            return (change.source, temporary, parent.appendingPathComponent(name))
        }

        let originalPaths = Set(prepared.map { $0.source.standardizedFileURL.path })
        let destinationPaths = prepared.map { $0.destination.standardizedFileURL.path }
        guard originalPaths.count == prepared.count,
              Set(destinationPaths).count == destinationPaths.count else {
            throw FileSystemServiceError.nameConflict
        }
        for entry in prepared where Self.entryExists(at: entry.destination) {
            guard originalPaths.contains(entry.destination.standardizedFileURL.path) else {
                throw FileSystemServiceError.nameConflict
            }
        }

        typealias RenameEntry = (source: URL, temporary: URL, destination: URL)
        func restore(_ staged: [RenameEntry], completed: [RenameEntry] = []) -> [URL] {
            var preserved: [URL] = []
            // First evacuate every final name, then restore original names.
            // Restoring directly fails for swaps/cycles (A→B, B→A).
            for entry in completed.reversed() {
                do { try manager.moveItem(at: entry.destination, to: entry.temporary) }
                catch { preserved.append(entry.destination) }
            }
            for entry in staged.reversed() where Self.entryExists(at: entry.temporary) {
                do { try manager.moveItem(at: entry.temporary, to: entry.source) }
                catch { preserved.append(entry.temporary) }
            }
            return preserved
        }
        var staged: [RenameEntry] = []
        do {
            for entry in prepared {
                try manager.moveItem(at: entry.source, to: entry.temporary)
                staged.append(entry)
            }
        } catch {
            let preserved = restore(staged)
            if !preserved.isEmpty {
                throw FileRecoveryError(underlyingError: error, preservedURLs: preserved)
            }
            throw error
        }

        var completed: [RenameEntry] = []
        do {
            for entry in staged {
                try manager.moveItem(at: entry.temporary, to: entry.destination)
                completed.append(entry)
            }
        } catch {
            let preserved = restore(staged, completed: completed)
            if !preserved.isEmpty {
                throw FileRecoveryError(underlyingError: error, preservedURLs: preserved)
            }
            throw error
        }
        return prepared.map(\.destination)
    }

    @discardableResult
    func trash(_ urls: [URL]) throws -> [(original: URL, trashed: URL)] {
        var results: [(original: URL, trashed: URL)] = []
        do {
            for url in urls {
                var resultingURL: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &resultingURL)
                guard let resultingURL else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let trashed = resultingURL as URL
                results.append((original: url, trashed: trashed))
            }
            return results
        } catch {
            for result in results.reversed() {
                try? manager.moveItem(at: result.trashed, to: result.original)
            }
            throw error
        }
    }

    func undoCreatedItems(_ urls: [URL]) throws {
        for url in urls.reversed() where Self.entryExists(at: url) {
            try manager.removeItem(at: url)
        }
    }

    func undoMoves(_ moves: [(current: URL, original: URL)]) throws {
        guard !moves.isEmpty else { return }
        for move in moves {
            guard Self.entryExists(at: move.current) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard !Self.entryExists(at: move.original) else {
                throw FileSystemServiceError.nameConflict
            }
        }

        var completed: [(current: URL, original: URL)] = []
        do {
            for move in moves {
                try manager.moveItem(at: move.current, to: move.original)
                completed.append(move)
            }
        } catch {
            for move in completed.reversed() {
                try? manager.moveItem(at: move.original, to: move.current)
            }
            throw error
        }
    }

    @discardableResult
    func duplicate(_ source: URL) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let sourceIsDirectory = isDirectory(source)
        let destination = uniqueDestination(
            named: duplicateName(for: source),
            in: parent,
            preservingExtension: !sourceIsDirectory
        )
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    func copy(_ urls: [URL], to directory: URL) throws {
        for source in urls {
            let sourceIsDirectory = isDirectory(source)
            let destination = uniqueDestination(
                named: source.lastPathComponent,
                in: directory,
                preservingExtension: !sourceIsDirectory
            )
            try manager.copyItem(at: source, to: destination)
        }
    }

    func move(_ urls: [URL], to directory: URL) throws {
        for source in urls {
            if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
                continue
            }
            let sourceIsDirectory = isDirectory(source)
            let destination = uniqueDestination(
                named: source.lastPathComponent,
                in: directory,
                preservingExtension: !sourceIsDirectory
            )
            try manager.moveItem(at: source, to: destination)
        }
    }

    func uniqueDestination(named originalName: String, in directory: URL, preservingExtension: Bool) -> URL {
        var candidate = directory.appendingPathComponent(originalName)
        guard Self.entryExists(at: candidate) else { return candidate }

        let nameURL = URL(fileURLWithPath: originalName)
        let pathExtension = preservingExtension ? nameURL.pathExtension : ""
        let stem = preservingExtension && !pathExtension.isEmpty
            ? nameURL.deletingPathExtension().lastPathComponent
            : originalName

        var index = 2
        repeat {
            let suffix = " \(index)"
            let candidateName = pathExtension.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(pathExtension)"
            candidate = directory.appendingPathComponent(candidateName)
            index += 1
        } while Self.entryExists(at: candidate)

        return candidate
    }

    private func duplicateName(for source: URL) -> String {
        let pathExtension = source.pathExtension
        let stem = pathExtension.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
        let copySuffix = L10n.text(" copy")
        return pathExtension.isEmpty ? "\(stem)\(copySuffix)" : "\(stem)\(copySuffix).\(pathExtension)"
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func item(for url: URL) -> FileItem? {
        item(
            for: url,
            resourceKeys: listingResourceKeys.union(tagResourceKeys).union([.volumeIsLocalKey])
        )
    }

    private func item(
        for url: URL,
        resourceKeys: Set<URLResourceKey>,
        volumeIsLocalOverride: Bool? = nil
    ) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        return FileItem(
            url: url,
            resourceValues: values,
            volumeIsLocalOverride: volumeIsLocalOverride
        )
    }
}

private struct FileSearchQuery {
    enum SizeComparison {
        case lessThan(Int64)
        case greaterThan(Int64)

        func matches(_ value: Int64) -> Bool {
            switch self {
            case .lessThan(let threshold): return value < threshold
            case .greaterThan(let threshold): return value > threshold
            }
        }
    }

    let terms: [String]
    let extensions: Set<String>
    let kind: String?
    let tag: String?
    let size: SizeComparison?
    let modifiedAfter: Date?

    var isEmpty: Bool {
        terms.isEmpty && extensions.isEmpty && kind == nil && tag == nil && size == nil && modifiedAfter == nil
    }

    init(_ rawValue: String) {
        var terms: [String] = []
        var extensions: Set<String> = []
        var kind: String?
        var tag: String?
        var size: SizeComparison?
        var modifiedAfter: Date?

        for token in rawValue.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                terms.append(token)
                continue
            }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch key {
            case "ext", "extension":
                extensions.formUnion(value.split(separator: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                })
            case "kind", "type":
                kind = value.lowercased()
            case "tag":
                tag = value
            case "size":
                size = Self.parseSize(value)
            case "modified", "date":
                modifiedAfter = Self.parseDate(value)
            default:
                terms.append(token)
            }
        }
        self.terms = terms
        self.extensions = extensions
        self.kind = kind
        self.tag = tag
        self.size = size
        self.modifiedAfter = modifiedAfter
    }

    func matches(_ item: FileItem) -> Bool {
        let searchable = item.name + " " + item.kind + " " + item.url.path
        guard terms.allSatisfy({ searchable.localizedCaseInsensitiveContains($0) }) else { return false }
        if !extensions.isEmpty, !extensions.contains(item.url.pathExtension.lowercased()) { return false }
        if let kind, !matches(kind: kind, item: item) { return false }
        if let size {
            guard !item.isDirectory, let byteCount = item.byteCount, size.matches(byteCount) else { return false }
        }
        if let modifiedAfter, (item.modifiedAt ?? .distantPast) < modifiedAfter { return false }
        if let tag {
            let tags = (try? item.url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            guard tags.contains(where: { $0.localizedCaseInsensitiveContains(tag) }) else { return false }
        }
        return true
    }

    private func matches(kind: String, item: FileItem) -> Bool {
        switch kind {
        case "folder", "directory": return item.isDirectory
        case "file": return !item.isDirectory
        case "image", "photo": return item.contentType?.conforms(to: .image) == true
        case "video", "movie": return item.contentType?.conforms(to: .movie) == true
        case "audio", "music": return item.contentType?.conforms(to: .audio) == true
        case "archive", "compressed": return item.contentType?.conforms(to: .archive) == true
        case "text": return item.contentType?.conforms(to: .text) == true
        case "pdf": return item.contentType?.conforms(to: .pdf) == true
        default: return item.kind.localizedCaseInsensitiveContains(kind)
        }
    }

    private static func parseSize(_ rawValue: String) -> SizeComparison? {
        let trimmed = rawValue.uppercased()
        guard let symbol = trimmed.first, symbol == ">" || symbol == "<" else { return nil }
        let valueWithUnit = String(trimmed.dropFirst())
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000), ("GB", 1_000_000_000),
            ("MB", 1_000_000), ("KB", 1_000), ("B", 1)
        ]
        let matchedUnit = units.first { valueWithUnit.hasSuffix($0.0) }
        let numberText = matchedUnit.map { String(valueWithUnit.dropLast($0.0.count)) } ?? valueWithUnit
        guard let number = Double(numberText) else { return nil }
        let bytes = Int64(number * (matchedUnit?.1 ?? 1))
        return symbol == ">" ? .greaterThan(bytes) : .lessThan(bytes)
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        switch rawValue.lowercased() {
        case "today": return calendar.startOfDay(for: now)
        case "week", "thisweek": return calendar.date(byAdding: .day, value: -7, to: now)
        case "month", "thismonth": return calendar.date(byAdding: .month, value: -1, to: now)
        case "year", "thisyear": return calendar.date(byAdding: .year, value: -1, to: now)
        default:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: rawValue)
        }
    }
}
