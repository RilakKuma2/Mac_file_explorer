import AppKit
import Testing
import UniformTypeIdentifiers
@testable import MacExplorer

@Suite("Default file viewer integration")
struct DefaultFileViewerTests {
    @Test("Sandboxed reveal senders can deliver files without taking over their default viewers")
    func sandboxedRevealDocumentTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let files = try #require(types.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("public.item") == true
        })
        #expect(files["CFBundleTypeRole"] as? String == "Viewer")
        #expect(files["LSHandlerRank"] as? String == "None")
        #expect(files["CFBundleTypeIconFile"] == nil)
        for type in [UTType.png, .jpeg, .pdf, .zip, .plainText, .movie, .package] {
            #expect(type.conforms(to: .item))
        }
        // Only real folders participate in default-handler selection. Do not
        // give generic files an Alternate/Default rank to work around AirDrop.
        for declaration in types where declaration["LSHandlerRank"] as? String != "None" {
            #expect(declaration["LSItemContentTypes"] as? [String] == ["public.folder"])
        }
    }

    @Test("Default viewer setup succeeds only when both system handlers match")
    func registrationVerification() {
        let identifier = "app.macexplorer.filemanager"
        #expect(DefaultFileViewer.Registration(folderHandler: identifier, fileViewer: identifier).matches(identifier))
        #expect(!DefaultFileViewer.Registration(folderHandler: identifier, fileViewer: "com.apple.finder").matches(identifier))
        #expect(!DefaultFileViewer.Registration(folderHandler: "com.apple.finder", fileViewer: identifier).matches(identifier))
        #expect(!DefaultFileViewer.Registration(folderHandler: nil, fileViewer: nil).matches(identifier))
    }

    @Test("Restoring Finder removes the alternate viewer override instead of opening files with Finder")
    func finderRestorationUsesSystemFallback() {
        let finder = DefaultFileViewer.finderIdentifier
        #expect(DefaultFileViewer.fileViewerOverride(for: finder) == nil)
        #expect(DefaultFileViewer.fileViewerOverride(for: "") == nil)
        #expect(DefaultFileViewer.fileViewerOverride(for: "app.macexplorer.filemanager") == "app.macexplorer.filemanager")
        #expect(DefaultFileViewer.fileViewerOverride(for: "com.example.other-viewer") == "com.example.other-viewer")
        #expect(DefaultFileViewer.Registration(folderHandler: finder, fileViewer: nil).matches(finder))
        #expect(!DefaultFileViewer.Registration(folderHandler: finder, fileViewer: finder).matches(finder))
        #expect(!DefaultFileViewer.Registration(folderHandler: finder, fileViewer: "app.macexplorer.filemanager").matches(finder))
        #expect(!DefaultFileViewer.Registration(folderHandler: "app.macexplorer.filemanager", fileViewer: nil).matches(finder))
        #expect(!DefaultFileViewer.Registration(folderHandler: nil, fileViewer: nil).matches(finder))
    }

    @Test("Desktop migration does not undo default app choices without a saved migration record")
    func legacyMigrationRequiresSavedState() throws {
        let suiteName = "MacExplorerTests.DefaultViewer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
        defaults.set(false, forKey: DefaultFileViewer.enabledKey)
        #expect(!FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
        defaults.set("com.apple.finder", forKey: "PreviousFolderHandlerBundleIdentifier")
        #expect(FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
        defaults.set(true, forKey: DefaultFileViewer.enabledKey)
        #expect(!FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
    }

    @Test("An explicitly empty previous viewer is still a real migration record")
    func legacyMigrationWithUnsetViewer() throws {
        let suiteName = "MacExplorerTests.DefaultViewer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: DefaultFileViewer.enabledKey)
        defaults.set("", forKey: "PreviousFileViewerBundleIdentifier")
        #expect(FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
        defaults.removeObject(forKey: "PreviousFileViewerBundleIdentifier")
        #expect(!FinderDesktopOpenInterceptor.hasLegacyRegistrationToRestore(defaults: defaults))
    }

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
