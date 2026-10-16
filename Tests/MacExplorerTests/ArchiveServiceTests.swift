import Foundation
import Testing
@testable import MacExplorer

@Suite("ArchiveService")
struct ArchiveServiceTests {
    @Test("Common libarchive formats are recognized")
    func recognizesExtractionFormats() {
        for name in [
            "archive.zip", "archive.zipx", "archive.7z", "archive.rar",
            "archive.tar.gz", "archive.tar.xz", "archive.cab", "archive.cpio",
            "archive.xar", "archive.lzh", "archive.iso", "package.deb"
        ] {
            #expect(ArchiveService.canExtract(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        #expect(!ArchiveService.canExtract(URL(fileURLWithPath: "/tmp/report.txt")))
    }

    @Test("Compound extensions are removed from extraction folder names")
    func stripsCompoundExtensions() {
        #expect(
            ArchiveService.extractionBaseName(
                for: URL(fileURLWithPath: "/tmp/photos.tar.bz2")
            ) == "photos"
        )
        #expect(
            ArchiveService.extractionBaseName(
                for: URL(fileURLWithPath: "/tmp/backup.7z")
            ) == "backup"
        )
    }

    @Test("Creation commands use the selected format")
    func choosesCreationCommand() {
        let source = URL(fileURLWithPath: "/tmp/Example Folder")
        let gzipDestination = URL(fileURLWithPath: "/tmp/Example Folder.tar.gz")
        let gzip = ArchiveService.creationCommand(
            format: .tarGzip,
            compressionLevel: .maximum,
            sources: [source],
            destination: gzipDestination
        )
        #expect(gzip?.executableURL.path == "/usr/bin/tar")
        #expect(gzip?.arguments.first == "-czf")
        #expect(gzip?.arguments.contains("gzip:compression-level=9") == true)
        #expect(gzip?.arguments.contains("-v") == true)
        if case .verbosePaths? = gzip?.progressReporting {
            // Expected: bsdtar reports completed paths for progress accounting.
        } else {
            Issue.record("TAR.GZ should expose verbose path progress")
        }

        let zipDestination = URL(fileURLWithPath: "/tmp/Example Folder.zip")
        let zip = ArchiveService.creationCommand(
            format: .zip,
            sources: [source],
            destination: zipDestination
        )
        #expect(zip?.executableURL.path == "/usr/bin/zip")
        #expect(zip?.arguments.contains("-6") == true)
        #expect(zip?.arguments.contains("-dg") == true)
        #expect(zip?.arguments.contains("1m") == true)
        if case let .zipDots(bytesPerDot)? = zip?.progressReporting {
            #expect(bytesPerDot == 1_048_576)
        } else {
            Issue.record("ZIP should expose byte-dot progress")
        }

        if ArchiveService.availableCreationFormats.contains(.tarZstd) {
            let zstandard = ArchiveService.creationCommand(
                format: .tarZstd,
                compressionLevel: .balanced,
                sources: [source],
                destination: URL(fileURLWithPath: "/tmp/Example Folder.tar.zst")
            )
            #expect(zstandard?.arguments.contains("--zstd") == true)
            #expect(zstandard?.arguments.contains("zstd:compression-level=3,zstd:threads=0") == true)
            #expect(zstandard?.environment?["PATH"]?.isEmpty == false)
        }
    }
}
