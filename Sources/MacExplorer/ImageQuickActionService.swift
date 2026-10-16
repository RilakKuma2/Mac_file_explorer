import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageQuickActionError: LocalizedError {
    case cannotReadImage
    case cannotWriteImage
    case cannotCreatePDF
    case noForeground
    case unsupportedSystem

    var errorDescription: String? {
        switch self {
        case .cannotReadImage: return L10n.text("The image could not be read.")
        case .cannotWriteImage: return L10n.text("The image could not be saved.")
        case .cannotCreatePDF: return L10n.text("The PDF could not be created.")
        case .noForeground: return L10n.text("No foreground subject was found.")
        case .unsupportedSystem: return L10n.text("This action requires macOS 14 or later.")
        }
    }
}

enum ImageConversionFormat: CaseIterable {
    case jpeg
    case png
    case heic

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIF"
        }
    }

    var uniformType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }

    var pathExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        }
    }
}

enum ImageConversionSize: CaseIterable {
    case actual
    case large
    case medium
    case small

    var title: String {
        switch self {
        case .actual: return L10n.text("Actual Size")
        case .large: return L10n.text("Large (1280 px)")
        case .medium: return L10n.text("Medium (640 px)")
        case .small: return L10n.text("Small (320 px)")
        }
    }

    var maximumDimension: CGFloat? {
        switch self {
        case .actual: return nil
        case .large: return 1280
        case .medium: return 640
        case .small: return 320
        }
    }
}

final class ImageQuickActionService {
    static let shared = ImageQuickActionService()

    private let context = CIContext(options: [.cacheIntermediates: true])
    private let manager = FileManager.default

    private init() {}

    func rotate(_ url: URL, clockwise: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageQuickActionError.cannotReadImage
        }

        let oriented = input.oriented(clockwise ? .right : .left)
        let normalized = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX,
            y: -oriented.extent.minY
        ))
        guard let image = context.createCGImage(normalized, from: normalized.extent) else {
            throw ImageQuickActionError.cannotReadImage
        }

        let temporary = temporaryURL(beside: url)
        do {
            try write(image, to: temporary, type: sourceType as String, properties: nil)
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    func createPDF(from urls: [URL], at destination: URL) throws {
        guard !urls.isEmpty,
              let consumer = CGDataConsumer(url: destination as CFURL) else {
            throw ImageQuickActionError.cannotCreatePDF
        }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw ImageQuickActionError.cannotCreatePDF
        }

        do {
            for url in urls {
                let image = try renderedImage(at: url)
                pdf.beginPDFPage(nil)
                pdf.interpolationQuality = .high
                let inset = page.insetBy(dx: 28, dy: 28)
                let scale = min(inset.width / CGFloat(image.width), inset.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let rect = CGRect(
                    x: page.midX - size.width / 2,
                    y: page.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                pdf.draw(image, in: rect)
                pdf.endPDFPage()
            }
            pdf.closePDF()
        } catch {
            pdf.closePDF()
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func convert(
        _ url: URL,
        to destination: URL,
        format: ImageConversionFormat,
        size: ImageConversionSize,
        preserveMetadata: Bool
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageQuickActionError.cannotReadImage
        }

        if let maximum = size.maximumDimension {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maximum {
                let scale = maximum / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        guard let output = context.createCGImage(image, from: image.extent) else {
            throw ImageQuickActionError.cannotReadImage
        }

        var properties: [CFString: Any] = [:]
        if preserveMetadata,
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = original
            properties[kCGImagePropertyOrientation] = 1
        }
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        try write(
            output,
            to: destination,
            type: format.uniformType.identifier,
            properties: properties as CFDictionary
        )
    }

    func removeBackground(from url: URL, to destination: URL) throws {
        guard #available(macOS 14.0, *) else { throw ImageQuickActionError.unsupportedSystem }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first,
              let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageQuickActionError.noForeground
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let transparent = CIImage(color: .clear).cropped(to: input.extent)
        let output = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: mask
        ])
        guard let image = context.createCGImage(output, from: output.extent) else {
            throw ImageQuickActionError.cannotWriteImage
        }
        try write(image, to: destination, type: UTType.png.identifier, properties: nil)
    }

    private func renderedImage(at url: URL) throws -> CGImage {
        guard let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageQuickActionError.cannotReadImage
        }
        let normalized = input.transformed(by: CGAffineTransform(
            translationX: -input.extent.minX,
            y: -input.extent.minY
        ))
        guard let image = context.createCGImage(normalized, from: normalized.extent) else {
            throw ImageQuickActionError.cannotReadImage
        }
        return image
    }

    private func write(
        _ image: CGImage,
        to destination: URL,
        type: String,
        properties: CFDictionary?
    ) throws {
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, type as CFString, 1, nil) else {
            throw ImageQuickActionError.cannotWriteImage
        }
        CGImageDestinationAddImage(writer, image, properties)
        guard CGImageDestinationFinalize(writer) else {
            throw ImageQuickActionError.cannotWriteImage
        }
    }

    private func temporaryURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".mac-explorer-\(UUID().uuidString).\(url.pathExtension)"
        )
    }
}
