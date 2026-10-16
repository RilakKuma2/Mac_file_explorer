import Foundation

struct FolderComparisonReport {
    let leftOnly: [String]
    let rightOnly: [String]
    let different: [String]
    let identicalCount: Int

    var summary: String {
        String(
            format: L10n.text("%d only on left, %d only on right, %d different, %d identical."),
            leftOnly.count, rightOnly.count, different.count, identicalCount
        )
    }

    var text: String {
        var lines: [String] = [summary, ""]
        append(title: L10n.text("Only on left"), values: leftOnly, marker: "←", to: &lines)
        append(title: L10n.text("Only on right"), values: rightOnly, marker: "→", to: &lines)
        append(title: L10n.text("Different"), values: different, marker: "≠", to: &lines)
        if leftOnly.isEmpty && rightOnly.isEmpty && different.isEmpty {
            lines.append(L10n.text("The folder contents match."))
        }
        return lines.joined(separator: "\n")
    }

    private func append(title: String, values: [String], marker: String, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(title) (\(values.count))")
        for value in values.prefix(2_000) { lines.append("\(marker)  \(value)") }
        if values.count > 2_000 {
            lines.append(String(format: L10n.text("…and %d more"), values.count - 2_000))
        }
        lines.append("")
    }
}

enum FolderComparisonService {
    private struct Entry {
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date?

        func differs(from other: Entry) -> Bool {
            guard isDirectory == other.isDirectory else { return true }
            if !isDirectory, size != other.size { return true }
            switch (modifiedAt, other.modifiedAt) {
            case let (left?, right?): return abs(left.timeIntervalSince(right)) > 1
            case (nil, nil): return false
            default: return true
            }
        }
    }

    static func compare(left: URL, right: URL) -> FolderComparisonReport {
        let leftEntries = entries(in: left)
        let rightEntries = entries(in: right)
        let leftPaths = Set(leftEntries.keys)
        let rightPaths = Set(rightEntries.keys)
        let common = leftPaths.intersection(rightPaths)
        let different = common.filter {
            guard let leftEntry = leftEntries[$0], let rightEntry = rightEntries[$0] else { return false }
            return leftEntry.differs(from: rightEntry)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return FolderComparisonReport(
            leftOnly: leftPaths.subtracting(rightPaths).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            rightOnly: rightPaths.subtracting(leftPaths).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            different: different,
            identicalCount: common.count - different.count
        )
    }

    private static func entries(in root: URL) -> [String: Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [:] }
        var result: [String: Entry] = [:]
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            result[relative] = Entry(
                isDirectory: values.isDirectory == true,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
        }
        return result
    }
}
