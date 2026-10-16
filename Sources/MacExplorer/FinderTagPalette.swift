import AppKit

struct FinderTag: Equatable {
    let name: String
    let colorIndex: Int
}

enum FinderTagPalette {
    // Finder presents favorites in visual spectrum order, while the legacy
    // file-label API indexes gray, green, purple, blue, yellow, red, orange.
    private static let favoriteSlotColorIndices = [6, 7, 5, 2, 4, 3, 1]
    private static let workspaceLabelNames = NSWorkspace.shared.fileLabels
    private static let workspaceLabelColors = NSWorkspace.shared.fileLabelColors

    static var favoriteTags: [FinderTag] {
        let workspaceNames = workspaceLabelNames
        let finderNames = UserDefaults(suiteName: "com.apple.finder")?
            .stringArray(forKey: "FavoriteTagNames") ?? []
        let colors = workspaceLabelColors
        let upperBound = min(colors.count, max(workspaceNames.count, finderNames.count))
        guard upperBound > 1 else { return [] }

        return (1..<upperBound).compactMap { index in
            let configuredName = finderNames.indices.contains(index)
                ? finderNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let systemName = workspaceNames.indices.contains(index)
                ? workspaceNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let name = configuredName.isEmpty ? systemName : configuredName
            guard !name.isEmpty else { return nil }
            let color = colorIndex(for: name)
                ?? favoriteSlotColorIndices[safe: index - 1]
                ?? index
            return FinderTag(name: name, colorIndex: color)
        }
    }

    static func colorIndex(for tagName: String) -> Int? {
        let components = tagName.split(separator: "\n", omittingEmptySubsequences: false)
        if components.count > 1,
           let encodedIndex = Int(components.last ?? ""),
           (1...7).contains(encodedIndex) {
            return encodedIndex
        }
        let normalizedName = components.first.map(String.init) ?? tagName
        return workspaceLabelNames.firstIndex {
            $0.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    static func displayName(for tagName: String) -> String {
        tagName.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? tagName
    }

    static func colors(for item: FileItem) -> [NSColor] {
        var indices: [Int] = []
        for name in item.tagNames {
            if let index = colorIndex(for: name), index > 0, !indices.contains(index) {
                indices.append(index)
            }
        }
        if item.labelNumber > 0, !indices.contains(item.labelNumber) {
            indices.insert(item.labelNumber, at: 0)
        }
        let colors = workspaceLabelColors
        return indices.prefix(4).compactMap { colors.indices.contains($0) ? colors[$0] : nil }
    }

    static func menuImage(forColorAt index: Int) -> NSImage? {
        let colors = workspaceLabelColors
        guard colors.indices.contains(index), index > 0 else { return nil }
        return dotImage(color: colors[index], diameter: 12)
    }

    static func dotImage(color: NSColor, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 0.7
        border.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class FinderTagDotsView: NSView {
    private var tagColors: [NSColor] = []

    func setColors(_ colors: [NSColor]) {
        let newColors = Array(colors.prefix(4))
        guard newColors != tagColors else { return }
        tagColors = newColors
        isHidden = tagColors.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        guard !tagColors.isEmpty else { return .zero }
        let diameter: CGFloat = 7
        let spacing: CGFloat = 2
        return NSSize(
            width: CGFloat(tagColors.count) * diameter + CGFloat(max(0, tagColors.count - 1)) * spacing,
            height: diameter
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let diameter: CGFloat = 7
        let spacing: CGFloat = 2
        for (index, color) in tagColors.enumerated() {
            let rect = NSRect(x: CGFloat(index) * (diameter + spacing), y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}
