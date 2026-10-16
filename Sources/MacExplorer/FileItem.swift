import Foundation
import UniformTypeIdentifiers

struct FileItem: Hashable {
    let url: URL
    let pathKey: String
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymbolicLink: Bool
    let isOnLocalVolume: Bool
    let modifiedAt: Date?
    let byteCount: Int64?
    let kind: String
    let contentType: UTType?
    private(set) var tagNames: [String]
    private(set) var labelNumber: Int

    init(
        url: URL,
        resourceValues: URLResourceValues,
        volumeIsLocalOverride: Bool? = nil
    ) {
        self.url = url
        self.pathKey = url.standardizedFileURL.path
        self.name = resourceValues.localizedName ?? FileManager.default.displayName(atPath: url.path)
        self.isDirectory = resourceValues.isDirectory ?? false
        self.isPackage = resourceValues.isPackage ?? false
        self.isHidden = resourceValues.isHidden ?? false
        self.isSymbolicLink = resourceValues.isSymbolicLink ?? false
        self.isOnLocalVolume = volumeIsLocalOverride ?? resourceValues.volumeIsLocal ?? false
        self.modifiedAt = resourceValues.contentModificationDate
        self.byteCount = resourceValues.fileSize.map(Int64.init)
        self.kind = resourceValues.localizedTypeDescription
            ?? (self.isDirectory ? L10n.text("Folder") : L10n.text("File"))
        self.contentType = resourceValues.contentType
        self.tagNames = resourceValues.tagNames ?? []
        self.labelNumber = resourceValues.labelNumber ?? 0
    }

    var isExtractableArchive: Bool {
        ArchiveService.canExtract(url)
    }

    func replacingTagMetadata(tagNames: [String], labelNumber: Int) -> FileItem {
        var copy = self
        copy.tagNames = tagNames
        copy.labelNumber = labelNumber
        return copy
    }
}

enum FileSortKey: Int, CaseIterable, Codable {
    case name
    case modifiedAt
    case kind
    case size
}

struct FileSortDescriptor {
    var key: FileSortKey = .name
    var ascending = true

    func sort(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let comparison: ComparisonResult
            switch key {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .modifiedAt:
                comparison = compare(lhs.modifiedAt, rhs.modifiedAt)
            case .kind:
                comparison = lhs.kind.localizedStandardCompare(rhs.kind)
            case .size:
                comparison = compare(lhs.byteCount, rhs.byteCount)
            }

            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?) where left < right:
            return .orderedAscending
        case let (left?, right?) where left > right:
            return .orderedDescending
        case (nil, .some):
            return .orderedAscending
        case (.some, nil):
            return .orderedDescending
        default:
            return .orderedSame
        }
    }
}
