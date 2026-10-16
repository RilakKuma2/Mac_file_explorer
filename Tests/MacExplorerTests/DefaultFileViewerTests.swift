import AppKit
import Testing
@testable import MacExplorer

@Suite("Default file viewer integration")
struct DefaultFileViewerTests {
    @Test("Reveal diagnostics describe formats without leaking filenames")
    func diagnosticPrivacy() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "/Users/private-person/secret-file.txt"), at: 1)
        list.insert(NSAppleEventDescriptor(string: "file:///private-secret"), at: 2)
        let summary = DefaultFileViewer.descriptorSummary(list)
        #expect(summary.contains("absolute-path"))
        #expect(summary.contains("file-url"))
        #expect(!summary.contains("private"))
        #expect(!summary.contains("secret"))
    }

    @Test("Reveal resolves file references before finding their parent folder")
    func revealFileReference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reference = try #require((file as NSURL).fileReferenceURL())
        let descriptor = try #require(NSAppleEventDescriptor(descriptorType: typeFileURL,
            data: Data(reference.absoluteString.utf8)))
        let decoded = try #require(DefaultFileViewer.revealedURLs(from: descriptor).first)
        #expect(decoded.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(!decoded.path.hasPrefix("/.file/"))
    }

    @Test("Reveal accepts text paths, nested lists and named file specifiers")
    func revealPathForms() throws {
        let url = URL(fileURLWithPath: "/tmp/받은 파일 #1.txt")
        let nested = NSAppleEventDescriptor.list()
        nested.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        nested.insert(NSAppleEventDescriptor(string: url.absoluteString), at: 2)
        let list = NSAppleEventDescriptor.list()
        list.insert(nested, at: 1)
        #expect(DefaultFileViewer.revealedURLs(from: list) == [url])
        let object = NSAppleEventDescriptor.record()
        object.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formName)), forKeyword: AEKeyword(keyAEKeyForm))
        object.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        object.setDescriptor(NSAppleEventDescriptor(string: url.path), forKeyword: AEKeyword(keyAEKeyData))
        let specifier = try #require(object.coerce(toDescriptorType: typeObjectSpecifier))
        #expect(DefaultFileViewer.revealedURLs(from: specifier) == [url])
        #expect(DefaultFileViewer.revealedURLs(from: NSAppleEventDescriptor(string: "https://example.com")).isEmpty)
        #expect(DefaultFileViewer.revealedURLs(from: NSAppleEventDescriptor(string: "relative.txt")).isEmpty)
    }

    @Test("Reveal registers the event declared by Finder's scripting dictionary")
    func standardRevealEvent() {
        #expect(DefaultFileViewer.revealEventClass == 0x6D697363)
        #expect(DefaultFileViewer.revealEventIDs.contains(0x6D766973))
    }
    @Test("Reveal requests preserve multiple file URLs including Unicode and spaces")
    func revealURLs() throws {
        let urls = [URL(fileURLWithPath: "/tmp/테스트 폴더/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            let descriptor = try #require(NSAppleEventDescriptor(descriptorType: typeFileURL,
                data: Data(url.absoluteString.utf8)))
            list.insert(descriptor, at: index + 1)
        }
        #expect(DefaultFileViewer.revealedURLs(from: list) == urls)
        #expect(DefaultFileViewer.revealedURLs(from: NSAppleEventDescriptor.list()).isEmpty)
    }

    @Test("Application icons use bundle artwork only on local volumes")
    @MainActor
    func applicationIcons() throws {
        let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .volumeIsLocalKey])
        let local = FileItem(url: url, resourceValues: values, volumeIsLocalOverride: true)
        let remote = FileItem(url: url, resourceValues: values, volumeIsLocalOverride: false)
        #expect(FileIconProvider.usesApplicationIcon(for: local))
        #expect(!FileIconProvider.usesApplicationIcon(for: remote))
        #expect(FileIconProvider.shared.icon(for: local).tiffRepresentation == NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation)
        let folder = url.deletingLastPathComponent()
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        #expect(!FileIconProvider.usesApplicationIcon(for: FileItem(url: folder,
            resourceValues: folderValues, volumeIsLocalOverride: true)))
    }
}
