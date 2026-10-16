import Foundation

struct DuplicateFileGroup {
    let digest: String
    let size: Int64
    let urls: [URL]
}

struct DuplicateFinderReport {
    let groups: [DuplicateFileGroup]
    let scannedFileCount: Int

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.urls.count } }
    var reclaimableBytes: Int64 { groups.reduce(0) { $0 + Int64(max(0, $1.urls.count - 1)) * $1.size } }

    var summary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return String(
            format: L10n.text("Found %d duplicate groups containing %d files. Up to %@ can be reclaimed."),
            groups.count,
            duplicateFileCount,
            formatter.string(fromByteCount: reclaimableBytes)
        )
    }

    var text: String {
        guard !groups.isEmpty else { return L10n.text("No duplicate files were found.") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var lines: [String] = [summary, ""]
        for (index, group) in groups.enumerated() {
            lines.append("#\(index + 1) · \(formatter.string(fromByteCount: group.size)) · SHA-256 \(group.digest)")
            lines.append(contentsOf: group.urls.map(\.path))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

enum DuplicateFinderService {
    static func find(in root: URL, showHidden: Bool, limit: Int = 100_000) -> DuplicateFinderReport {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) else { return DuplicateFinderReport(groups: [], scannedFileCount: 0) }

        var filesBySize: [Int64: [URL]] = [:]
        var scanned = 0
        for case let url as URL in enumerator {
            if Task.isCancelled || scanned >= limit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            scanned += 1
            filesBySize[Int64(values.fileSize ?? 0), default: []].append(url)
        }

        var duplicateGroups: [DuplicateFileGroup] = []
        for (size, candidates) in filesBySize where candidates.count > 1 {
            if Task.isCancelled { break }
            var byDigest: [String: [URL]] = [:]
            for url in candidates {
                guard !Task.isCancelled,
                      let result = try? ChecksumService.sha256(for: [url]).first else { continue }
                byDigest[result.digest, default: []].append(url)
            }
            for (digest, urls) in byDigest where urls.count > 1 {
                duplicateGroups.append(.init(digest: digest, size: size, urls: urls.sorted { $0.path < $1.path }))
            }
        }
        duplicateGroups.sort {
            let lhsWaste = Int64(max(0, $0.urls.count - 1)) * $0.size
            let rhsWaste = Int64(max(0, $1.urls.count - 1)) * $1.size
            return lhsWaste == rhsWaste ? $0.urls[0].path < $1.urls[0].path : lhsWaste > rhsWaste
        }
        return DuplicateFinderReport(groups: duplicateGroups, scannedFileCount: scanned)
    }
}
