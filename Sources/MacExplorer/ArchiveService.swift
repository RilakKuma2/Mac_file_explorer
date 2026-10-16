import Foundation

enum ArchiveCreationFormat: String, CaseIterable {
    case zip
    case sevenZip
    case tarGzip
    case tarZstd
    case tar
    case iso
    case tarBzip2
    case tarXz
    case xar
    case pax
    case cpio
    case shar
    case ar
    case warc

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .tarZstd: return "ZST"
        case .xar: return "XAR"
        case .pax: return "PAX"
        case .cpio: return "CPIO"
        case .shar: return "SHAR"
        case .sevenZip: return "7Z"
        case .ar: return "AR"
        case .iso: return "ISO"
        case .warc: return "WARC"
        }
    }

    var filenameSuffix: String {
        switch self {
        case .zip: return ".zip"
        case .tar: return ".tar"
        case .tarGzip: return ".tar.gz"
        case .tarBzip2: return ".tar.bz2"
        case .tarXz: return ".tar.xz"
        case .tarZstd: return ".tar.zst"
        case .xar: return ".xar"
        case .pax: return ".pax"
        case .cpio: return ".cpio"
        case .shar: return ".shar"
        case .sevenZip: return ".7z"
        case .ar: return ".ar"
        case .iso: return ".iso"
        case .warc: return ".warc"
        }
    }

    var supportsCompressionLevel: Bool {
        switch self {
        case .zip, .sevenZip, .tarGzip, .tarBzip2, .tarXz, .tarZstd: return true
        default: return false
        }
    }

    var isCommon: Bool {
        switch self {
        case .zip, .sevenZip, .tarGzip, .tarZstd, .tar, .iso: return true
        default: return false
        }
    }
}

enum ArchiveCompressionLevel: String, CaseIterable {
    case fastest
    case balanced
    case maximum

    var title: String {
        switch self {
        case .fastest: return L10n.text("Fastest")
        case .balanced: return L10n.text("Balanced (Recommended)")
        case .maximum: return L10n.text("Maximum compression")
        }
    }

    var conventionalValue: Int {
        switch self {
        case .fastest: return 1
        case .balanced: return 6
        case .maximum: return 9
        }
    }

    var sevenZipValue: Int {
        switch self {
        case .fastest: return 1
        case .balanced: return 5
        case .maximum: return 9
        }
    }

    var zstandardValue: Int {
        switch self {
        case .fastest: return 1
        case .balanced: return 3
        case .maximum: return 19
        }
    }
}

struct ArchiveCommand {
    enum ProgressReporting {
        case none
        case zipDots(bytesPerDot: Int64)
        case percentage
        case verbosePaths
    }

    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let environment: [String: String]?
    let progressReporting: ProgressReporting

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]? = nil,
        progressReporting: ProgressReporting = .none
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.progressReporting = progressReporting
    }
}

enum ArchiveService {
    // Extraction is backed by macOS bsdtar/libarchive. Keep longer compound
    // extensions first so generated destination names are correct.
    static let extractableSuffixes = [
        ".tar.bz2", ".tar.lzma", ".tar.lzip", ".tar.lz4", ".tar.lzo", ".tar.zst",
        ".tar.gz", ".tar.xz", ".tar.lz", ".tar.z",
        ".tbz2", ".tlz", ".tbz", ".tgz", ".txz", ".tzst", ".taz",
        ".zipx", ".zip", ".7z", ".rar", ".cab", ".cpio", ".xar", ".pax", ".shar",
        ".lha", ".lzh", ".warc", ".iso", ".deb", ".ar", ".tar"
    ]

    static func canExtract(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return extractableSuffixes.contains { name.hasSuffix($0) }
    }

    static var availableCreationFormats: [ArchiveCreationFormat] {
        ArchiveCreationFormat.allCases.filter { format in
            format != .tarZstd || helperURL(named: "zstd") != nil
        }
    }

    static func extractionBaseName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        if let suffix = extractableSuffixes.first(where: { name.lowercased().hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        return archive.deletingPathExtension().lastPathComponent
    }

    static func uniqueDestination(
        baseName: String,
        format: ArchiveCreationFormat,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        var index = 1
        while true {
            let numberedBase = index == 1 ? baseName : "\(baseName) \(index)"
            let candidate = directory.appendingPathComponent(numberedBase + format.filenameSuffix)
            if !FileSystemService.entryExists(at: candidate) { return candidate }
            index += 1
        }
    }

    static func creationCommand(
        format: ArchiveCreationFormat,
        compressionLevel: ArchiveCompressionLevel = .balanced,
        sources: [URL],
        destination: URL
    ) -> ArchiveCommand? {
        guard let parent = sources.first?.deletingLastPathComponent(),
              sources.allSatisfy({
                  $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL
              }) else { return nil }

        let relativeNames = sources.map(\.lastPathComponent)
        switch format {
        case .zip:
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: [
                    "-r", "-q", "-dg", "-ds", "1m", "-\(compressionLevel.conventionalValue)",
                    destination.path, "--"
                ] + relativeNames.map { "./" + $0 },
                currentDirectoryURL: parent,
                progressReporting: .zipDots(bytesPerDot: 1_048_576)
            )
        case .sevenZip:
            if let sevenZip = helperURL(named: "7z") ?? helperURL(named: "7zz") {
                return ArchiveCommand(
                    executableURL: sevenZip,
                    arguments: [
                        "a", "-t7z", "-mx=\(compressionLevel.sevenZipValue)",
                        "-mmt=on", "-bsp1", "-bb0", destination.path, "--"
                    ] + relativeNames,
                    currentDirectoryURL: parent,
                    environment: environment(including: sevenZip),
                    progressReporting: .percentage
                )
            }
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: [
                    "-cf", destination.path, "-v", "--format", "7zip", "--options",
                    "7zip:compression=lzma2,7zip:compression-level=\(compressionLevel.sevenZipValue)",
                    "-C", parent.path, "--"
                ] + relativeNames,
                currentDirectoryURL: nil,
                progressReporting: .verbosePaths
            )
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            let mode: String
            let options: String?
            switch format {
            case .tar:
                mode = "-cf"
                options = nil
            case .tarGzip:
                mode = "-czf"
                options = "gzip:compression-level=\(compressionLevel.conventionalValue)"
            case .tarBzip2:
                mode = "-cjf"
                options = "bzip2:compression-level=\(compressionLevel.conventionalValue)"
            case .tarXz:
                mode = "-cJf"
                options = "xz:compression-level=\(compressionLevel.conventionalValue),xz:threads=0"
            default: return nil
            }
            var arguments = [mode, destination.path]
            arguments.append("-v")
            if let options { arguments += ["--options", options] }
            arguments += ["-C", parent.path, "--"] + relativeNames
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: arguments,
                currentDirectoryURL: nil,
                progressReporting: .verbosePaths
            )
        case .tarZstd:
            guard let zstandard = helperURL(named: "zstd") else { return nil }
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: [
                    "--zstd", "-cf", destination.path, "-v", "--options",
                    "zstd:compression-level=\(compressionLevel.zstandardValue),zstd:threads=0",
                    "-C", parent.path, "--"
                ] + relativeNames,
                currentDirectoryURL: nil,
                environment: environment(including: zstandard),
                progressReporting: .verbosePaths
            )
        case .xar:
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/xar"),
                arguments: ["-cvf", destination.path] + relativeNames.map { "./" + $0 },
                currentDirectoryURL: parent,
                progressReporting: .verbosePaths
            )
        case .pax, .cpio, .shar, .ar, .iso, .warc:
            let archiveFormat: String
            switch format {
            case .pax: archiveFormat = "pax"
            case .cpio: archiveFormat = "cpio"
            case .shar: archiveFormat = "shar"
            case .ar: archiveFormat = "ar"
            case .iso: archiveFormat = "iso9660"
            case .warc: archiveFormat = "warc"
            default: return nil
            }
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: [
                    "-cf", destination.path, "-v", "--format", archiveFormat,
                    "-C", parent.path, "--"
                ] + relativeNames,
                currentDirectoryURL: nil,
                progressReporting: .verbosePaths
            )
        }
    }

    private static func helperURL(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Helpers/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/opt/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
            URL(fileURLWithPath: "/bin/\(name)")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func environment(including helperURL: URL) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let helperDirectory = helperURL.deletingLastPathComponent().path
        let existingDirectories = result["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
            .split(separator: ":")
            .map(String.init)
        result["PATH"] = ([helperDirectory] + existingDirectories)
            .reduce(into: [String]()) { directories, directory in
                if !directories.contains(directory) { directories.append(directory) }
            }
            .joined(separator: ":")
        return result
    }

    static func extractionCommand(archive: URL, destination: URL) -> ArchiveCommand {
        if archive.lastPathComponent.lowercased().hasSuffix(".zip") {
            return ArchiveCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, destination.path],
                currentDirectoryURL: nil
            )
        }
        let lowercasedName = archive.lastPathComponent.lowercased()
        let helperName: String?
        if lowercasedName.hasSuffix(".zst") || lowercasedName.hasSuffix(".tzst") {
            helperName = "zstd"
        } else if lowercasedName.hasSuffix(".lz4") {
            helperName = "lz4"
        } else if lowercasedName.hasSuffix(".lzip") || lowercasedName.hasSuffix(".lz") {
            helperName = "lzip"
        } else if lowercasedName.hasSuffix(".lzo") {
            helperName = "lzop"
        } else {
            helperName = nil
        }
        let helper = helperName.flatMap { helperURL(named: $0) }
        return ArchiveCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", destination.path],
            currentDirectoryURL: nil,
            environment: helper.map { environment(including: $0) }
        )
    }
}
