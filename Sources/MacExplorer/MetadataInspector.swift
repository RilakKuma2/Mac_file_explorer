import AVFoundation
import CoreMedia
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InspectorProperty {
    let label: String
    let value: String
}

struct InspectorSection {
    let title: String
    var properties: [InspectorProperty]
}

enum MetadataInspector {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func inspect(_ item: FileItem) async -> [InspectorSection] {
        let operation = Task.detached(priority: .userInitiated) {
            var sections: [InspectorSection] = []
            if let general = generalSection(for: item) { sections.append(general) }

            if item.isDirectory {
                if let folder = folderSection(for: item.url) { sections.append(folder) }
                return sections
            }

            if item.contentType?.conforms(to: .image) == true,
               let image = imageSection(for: item.url) {
                sections.append(image)
            }

            if item.contentType?.conforms(to: .movie) == true
                || item.contentType?.conforms(to: .audio) == true
                || item.contentType?.conforms(to: .audiovisualContent) == true {
                sections.append(contentsOf: await mediaSections(for: item.url))
            }
            return sections
        }
        return await withTaskCancellationHandler(
            operation: { await operation.value },
            onCancel: { operation.cancel() }
        )
    }

    static func inspect(_ items: [FileItem]) async -> [InspectorSection] {
        let operation = Task.detached(priority: .userInitiated) {
            selectionSections(for: items)
        }
        return await withTaskCancellationHandler(
            operation: { await operation.value },
            onCancel: { operation.cancel() }
        )
    }

    private static func selectionSections(for items: [FileItem]) -> [InspectorSection] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey]
        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0

        for item in items {
            if Task.isCancelled { return [] }
            if item.isDirectory {
                folderCount += 1
                guard let enumerator = FileManager.default.enumerator(
                    at: item.url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else { continue }
                for case let child as URL in enumerator {
                    if Task.isCancelled { return [] }
                    guard let values = try? child.resourceValues(forKeys: keys) else { continue }
                    if values.isDirectory == true {
                        folderCount += 1
                    } else {
                        fileCount += 1
                        totalSize += Int64(values.totalFileSize ?? values.fileSize ?? 0)
                    }
                }
            } else {
                fileCount += 1
                totalSize += item.byteCount ?? 0
            }
        }

        return [InspectorSection(title: L10n.text("Selection summary"), properties: [
            .init(label: L10n.text("Selected items"), value: formattedInteger(items.count)),
            .init(label: L10n.text("Files"), value: formattedInteger(fileCount)),
            .init(label: L10n.text("Folders"), value: formattedInteger(folderCount)),
            .init(label: L10n.text("Total size"), value: byteFormatter.string(fromByteCount: totalSize))
        ])]
    }

    private static func generalSection(for item: FileItem) -> InspectorSection? {
        var properties: [InspectorProperty] = []
        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .tagNamesKey,
            .contentTypeKey
        ]
        let values = try? item.url.resourceValues(forKeys: keys)

        if item.isSymbolicLink {
            properties.append(.init(label: L10n.text("Item type"), value: L10n.text("Symbolic link")))
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path) {
                properties.append(.init(label: L10n.text("Link destination"), value: destination))
            }
        }
        if !item.url.pathExtension.isEmpty {
            properties.append(.init(label: L10n.text("Format"), value: item.url.pathExtension.uppercased()))
        }
        if let type = values?.contentType ?? item.contentType {
            properties.append(.init(label: L10n.text("Content type"), value: type.identifier))
        }
        if let date = values?.creationDate {
            properties.append(.init(label: L10n.text("Created"), value: dateFormatter.string(from: date)))
        }
        if let date = values?.addedToDirectoryDate {
            properties.append(.init(label: L10n.text("Date added"), value: dateFormatter.string(from: date)))
        }
        if let date = values?.contentAccessDate {
            properties.append(.init(label: L10n.text("Last opened"), value: dateFormatter.string(from: date)))
        }
        let allocatedSize = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
        if let allocatedSize, !item.isDirectory {
            properties.append(.init(
                label: L10n.text("Size on disk"),
                value: byteFormatter.string(fromByteCount: Int64(allocatedSize))
            ))
        }
        if let tags = values?.tagNames, !tags.isEmpty {
            properties.append(.init(label: L10n.text("Tags"), value: tags.joined(separator: ", ")))
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path) {
            if let owner = attributes[.ownerAccountName] as? String, !owner.isEmpty {
                properties.append(.init(label: L10n.text("Owner"), value: owner))
            }
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                properties.append(.init(
                    label: L10n.text("Permissions"),
                    value: String(format: "%03o", permissions.uint16Value)
                ))
            }
        }
        return properties.isEmpty ? nil : InspectorSection(title: L10n.text("File information"), properties: properties)
    }

    private static func folderSection(for url: URL) -> InspectorSection? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                folderCount += 1
            } else {
                fileCount += 1
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        return InspectorSection(title: L10n.text("Folder contents"), properties: [
            .init(label: L10n.text("Files"), value: formattedInteger(fileCount)),
            .init(label: L10n.text("Folders"), value: formattedInteger(folderCount)),
            .init(label: L10n.text("Total size"), value: byteFormatter.string(fromByteCount: totalSize))
        ])
    }

    private static func imageSection(for url: URL) -> InspectorSection? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let dictionary = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        var properties: [InspectorProperty] = []
        let width = (dictionary[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (dictionary[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        if let width, let height, width > 0, height > 0 {
            properties.append(.init(label: L10n.text("Dimensions"), value: "\(width) × \(height) px"))
            properties.append(.init(label: L10n.text("Aspect ratio"), value: aspectRatio(width: width, height: height)))
        }
        if let typeIdentifier = CGImageSourceGetType(source) as String?,
           let type = UTType(typeIdentifier) {
            let format = type.preferredFilenameExtension?.uppercased() ?? type.localizedDescription ?? type.identifier
            properties.append(.init(label: L10n.text("Image format"), value: format))
        }
        if let model = dictionary[kCGImagePropertyColorModel] as? String {
            properties.append(.init(label: L10n.text("Color model"), value: model))
        }
        if let profile = (dictionary[kCGImagePropertyProfileName] as? String)
            ?? (dictionary[kCGImagePropertyNamedColorSpace] as? String) {
            properties.append(.init(label: L10n.text("Color profile"), value: profile))
        }
        if let depth = dictionary[kCGImagePropertyDepth] as? NSNumber {
            properties.append(.init(label: L10n.text("Bit depth"), value: "\(depth.intValue)-bit"))
        }
        let dpiWidth = (dictionary[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        let dpiHeight = (dictionary[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        if let dpiWidth {
            let dpi = dpiHeight.map { "\(formatDecimal(dpiWidth)) × \(formatDecimal($0)) dpi" }
                ?? "\(formatDecimal(dpiWidth)) dpi"
            properties.append(.init(label: L10n.text("Resolution"), value: dpi))
        }
        if let hasAlpha = dictionary[kCGImagePropertyHasAlpha] as? NSNumber {
            properties.append(.init(label: L10n.text("Alpha channel"), value: L10n.text(hasAlpha.boolValue ? "Yes" : "No")))
        }
        let imageCount = CGImageSourceGetCount(source)
        if imageCount > 1 {
            properties.append(.init(label: L10n.text("Frame count"), value: formattedInteger(imageCount)))
        }

        if let exif = dictionary[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let originalDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            properties.append(.init(label: L10n.text("Date taken"), value: originalDate))
        }
        if let tiff = dictionary[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            let camera = [make, model].compactMap { $0 }.joined(separator: " ")
            if !camera.isEmpty { properties.append(.init(label: L10n.text("Camera"), value: camera)) }
        }
        return properties.isEmpty ? nil : InspectorSection(title: L10n.text("Image"), properties: properties)
    }

    private static func mediaSections(for url: URL) async -> [InspectorSection] {
        let asset = AVURLAsset(url: url)
        var general: [InspectorProperty] = []
        var video: [InspectorProperty] = []
        var audio: [InspectorProperty] = []
        var totalBitRate: Double = 0

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds >= 0 {
                general.append(.init(label: L10n.text("Duration"), value: formatDuration(seconds)))
            }
        }

        let tracks = (try? await asset.load(.tracks)) ?? []
        for track in tracks {
            let dataRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            totalBitRate += max(0, dataRate)
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let codec = descriptions.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) }

            if track.mediaType == .video {
                let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let displayed = naturalSize.applying(transform)
                let width = Int(abs(displayed.width).rounded())
                let height = Int(abs(displayed.height).rounded())
                if width > 0, height > 0 {
                    video.append(.init(label: L10n.text("Resolution"), value: "\(width) × \(height) px"))
                    video.append(.init(label: L10n.text("Aspect ratio"), value: aspectRatio(width: width, height: height)))
                }
                if let codec { video.append(.init(label: L10n.text("Video codec"), value: codec)) }
                let frameRate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                if frameRate > 0 {
                    video.append(.init(label: L10n.text("Frame rate"), value: "\(formatDecimal(frameRate)) fps"))
                }
                if dataRate > 0 {
                    video.append(.init(label: L10n.text("Video bit rate"), value: formatBitRate(dataRate)))
                }
            } else if track.mediaType == .audio {
                if let codec { audio.append(.init(label: L10n.text("Audio codec"), value: codec)) }
                if dataRate > 0 {
                    audio.append(.init(label: L10n.text("Audio bit rate"), value: formatBitRate(dataRate)))
                }
                if let description = descriptions.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    if basic.mSampleRate > 0 {
                        audio.append(.init(label: L10n.text("Sample rate"), value: formatSampleRate(basic.mSampleRate)))
                    }
                    if basic.mChannelsPerFrame > 0 {
                        audio.append(.init(
                            label: L10n.text("Channels"),
                            value: channelDescription(Int(basic.mChannelsPerFrame))
                        ))
                    }
                    if basic.mBitsPerChannel > 0 {
                        audio.append(.init(
                            label: L10n.text("Audio bit depth"),
                            value: "\(basic.mBitsPerChannel)-bit"
                        ))
                    }
                }
            }
        }

        if totalBitRate > 0 {
            general.append(.init(label: L10n.text("Total bit rate"), value: formatBitRate(totalBitRate)))
        }
        appendSpotlightFallback(for: url, general: &general, video: &video, audio: &audio)

        var sections: [InspectorSection] = []
        if !general.isEmpty { sections.append(.init(title: L10n.text("Media"), properties: general)) }
        if !video.isEmpty { sections.append(.init(title: L10n.text("Video"), properties: video)) }
        if !audio.isEmpty { sections.append(.init(title: L10n.text("Audio"), properties: audio)) }
        return sections
    }

    private static func appendSpotlightFallback(
        for url: URL,
        general: inout [InspectorProperty],
        video: inout [InspectorProperty],
        audio: inout [InspectorProperty]
    ) {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return }
        func attribute(_ key: CFString) -> Any? { MDItemCopyAttribute(item, key) }
        func has(_ label: String, in values: [InspectorProperty]) -> Bool { values.contains { $0.label == label } }

        let durationLabel = L10n.text("Duration")
        if !has(durationLabel, in: general), let seconds = (attribute(kMDItemDurationSeconds) as? NSNumber)?.doubleValue {
            general.append(.init(label: durationLabel, value: formatDuration(seconds)))
        }
        let codecValues = attribute(kMDItemCodecs) as? [String]
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let codecValues, codecValues.count == 1, let codec = codecValues.first {
            if contentType?.conforms(to: .audio) == true, contentType?.conforms(to: .movie) != true {
                if !has(L10n.text("Audio codec"), in: audio) {
                    audio.append(.init(label: L10n.text("Audio codec"), value: codec))
                }
            } else if !has(L10n.text("Video codec"), in: video) {
                video.append(.init(label: L10n.text("Video codec"), value: codec))
            }
        } else if let codecValues {
            if let codec = codecValues.first, !has(L10n.text("Video codec"), in: video) {
                video.append(.init(label: L10n.text("Video codec"), value: codec))
            }
            if let codec = codecValues.last, !has(L10n.text("Audio codec"), in: audio) {
                audio.append(.init(label: L10n.text("Audio codec"), value: codec))
            }
        }
        if !has(L10n.text("Total bit rate"), in: general),
           let rate = (attribute(kMDItemTotalBitRate) as? NSNumber)?.doubleValue, rate > 0 {
            general.append(.init(label: L10n.text("Total bit rate"), value: formatBitRate(rate)))
        }
        if !has(L10n.text("Resolution"), in: video),
           let width = (attribute(kMDItemPixelWidth) as? NSNumber)?.intValue,
           let height = (attribute(kMDItemPixelHeight) as? NSNumber)?.intValue,
           width > 0, height > 0 {
            video.append(.init(label: L10n.text("Resolution"), value: "\(width) × \(height) px"))
            video.append(.init(label: L10n.text("Aspect ratio"), value: aspectRatio(width: width, height: height)))
        }
        if !has(L10n.text("Video bit rate"), in: video),
           let rate = (attribute(kMDItemVideoBitRate) as? NSNumber)?.doubleValue, rate > 0 {
            video.append(.init(label: L10n.text("Video bit rate"), value: formatBitRate(rate)))
        }
        if !has(L10n.text("Audio bit rate"), in: audio),
           let rate = (attribute(kMDItemAudioBitRate) as? NSNumber)?.doubleValue, rate > 0 {
            audio.append(.init(label: L10n.text("Audio bit rate"), value: formatBitRate(rate)))
        }
        if !has(L10n.text("Sample rate"), in: audio),
           let rate = (attribute(kMDItemAudioSampleRate) as? NSNumber)?.doubleValue, rate > 0 {
            audio.append(.init(label: L10n.text("Sample rate"), value: formatSampleRate(rate)))
        }
        if !has(L10n.text("Channels"), in: audio),
           let channels = (attribute(kMDItemAudioChannelCount) as? NSNumber)?.intValue, channels > 0 {
            audio.append(.init(label: L10n.text("Channels"), value: channelDescription(channels)))
        }
    }

    private static func aspectRatio(width: Int, height: Int) -> String {
        let divisor = greatestCommonDivisor(width, height)
        let ratio = "\(width / divisor):\(height / divisor)"
        return "\(ratio) (\(formatDecimal(Double(width) / Double(height))))"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let raw = fourCharacterString(code)
        let names: [String: String] = [
            "avc1": "H.264 / AVC", "avc3": "H.264 / AVC", "hvc1": "HEVC / H.265",
            "hev1": "HEVC / H.265", "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4 Video",
            "ap4h": "Apple ProRes 4444", "ap4x": "Apple ProRes 4444 XQ", "apch": "Apple ProRes 422 HQ",
            "apcn": "Apple ProRes 422", "apcs": "Apple ProRes 422 LT", "apco": "Apple ProRes 422 Proxy",
            "mp4a": "AAC", "aac ": "AAC", "alac": "Apple Lossless (ALAC)", "ac-3": "Dolby Digital (AC-3)",
            "ec-3": "Dolby Digital Plus (E-AC-3)", "Opus": "Opus", "fLaC": "FLAC", "lpcm": "Linear PCM"
        ]
        return names[raw] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fourCharacterString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08X", code)
    }

    private static func formatBitRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? "\(formatDecimal(bitsPerSecond / 1_000_000)) Mbps"
            : "\(formatDecimal(bitsPerSecond / 1_000)) kbps"
    }

    private static func formatSampleRate(_ samplesPerSecond: Double) -> String {
        samplesPerSecond >= 1_000
            ? "\(formatDecimal(samplesPerSecond / 1_000)) kHz"
            : "\(formatDecimal(samplesPerSecond)) Hz"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3_600
        let minutes = (rounded % 3_600) / 60
        let remaining = rounded % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }

    private static func channelDescription(_ channels: Int) -> String {
        switch channels {
        case 1: return L10n.text("Mono") + " (1)"
        case 2: return L10n.text("Stereo") + " (2)"
        default: return String(format: L10n.text("%d channels"), channels)
        }
    }

    private static func formattedInteger(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func formatDecimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
