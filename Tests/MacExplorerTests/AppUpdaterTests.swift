import Foundation
import Testing
@testable import MacExplorer

@Suite("App updater")
struct AppUpdaterTests {
    @Test("Legacy feed keys stay in Info.plist so 0.1.1 and earlier can still update")
    func legacyFeedConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == "https://github.com/RilakKuma2/Mac_file_explorer/releases/latest/download/appcast.xml")
        let key = try #require(plist["SUPublicEDKey"] as? String)
        #expect(plist["CFBundleIdentifier"] as? String == "app.macexplorer.filemanager")
        #expect(Data(base64Encoded: key)?.count == 32)
        // generate_appcast signs the feed only when the app asks for a signed
        // feed, and 0.1.1 refuses an unsigned one.
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(AppVersion(try #require(plist["CFBundleShortVersionString"] as? String)) != nil)
    }

    @Test("Versions compare numerically and ignore the tag prefix and trailing zeros")
    func versions() throws {
        let v011 = try #require(AppVersion("0.1.1"))
        #expect(try #require(AppVersion("v0.1.2")) > v011)
        #expect(try #require(AppVersion("0.10")) > (try #require(AppVersion("0.9.9"))))
        #expect(AppVersion("0.1") == AppVersion("V0.1.0"))
        #expect(try #require(AppVersion("0.1")) < v011)
        #expect(AppVersion("1.2.3.4") != nil)
        for invalid in ["", "v", "1..2", "1.2-beta", "latest", "1.2.3.4.5", "-1.0"] {
            #expect(AppVersion(invalid) == nil)
        }
        #expect(v011.description == "0.1.1")
    }

    private func release(_ tag: String, body: String? = nil, assets: [(String, String)] = [],
                         draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(
            tagName: tag, body: body, draft: draft, prerelease: prerelease,
            htmlURL: "https://github.com/RilakKuma2/Mac_file_explorer/releases/tag/\(tag)",
            assets: assets.map { GitHubRelease.Asset(name: $0.0, browserDownloadURL: $0.1) }
        )
    }

    @Test("Only this project's disk image for this architecture is offered")
    func availability() throws {
        let current = try #require(AppVersion("0.1.1"))
        let base = "https://github.com/RilakKuma2/Mac_file_explorer/releases/download/v0.1.2/"
        let assets = [
            ("appcast.xml", base + "appcast.xml"),
            ("Mac-Explorer-0.1.2-arm64.zip", base + "Mac-Explorer-0.1.2-arm64.zip"),
            ("Mac-Explorer-0.1.2-arm64.dmg", base + "Mac-Explorer-0.1.2-arm64.dmg")
        ]
        guard case let .available(offer) = try UpdateCatalog.availability(
            of: release("v0.1.2", assets: assets), current: current, architecture: "arm64"
        ) else { Issue.record("expected an offer"); return }
        #expect(offer.assetName == "Mac-Explorer-0.1.2-arm64.dmg")
        #expect(offer.downloadURL.absoluteString == base + "Mac-Explorer-0.1.2-arm64.dmg")
        #expect(offer.version == AppVersion("0.1.2"))

        #expect(try UpdateCatalog.availability(of: release("v0.1.1", assets: assets), current: current)
            == .current(latest: current))
        #expect(try UpdateCatalog.availability(of: release("v0.1", assets: assets), current: current)
            == .current(latest: try #require(AppVersion("0.1"))))
        guard case .missingAsset = try UpdateCatalog.availability(
            of: release("v0.1.2", assets: assets), current: current, architecture: "x86_64"
        ) else { Issue.record("expected a missing asset"); return }

        let foreign = [("Mac-Explorer-0.1.2-arm64.dmg", "https://example.com/Mac-Explorer-0.1.2-arm64.dmg")]
        #expect(throws: UpdateError.self) {
            try UpdateCatalog.availability(of: release("v0.1.2", assets: foreign), current: current, architecture: "arm64")
        }
        #expect(throws: UpdateError.self) {
            try UpdateCatalog.availability(of: release("nightly", assets: assets), current: current)
        }
    }

    @Test("Update notes contain only the changes of every pending public version")
    func releaseNotes() throws {
        let body = "## 개선 및 수정\n\n- **주소창** 클릭 수정\n- [링크](https://example.com) 정리\n\n## 설치 및 업데이트\n\nDMG를 여세요."
        #expect(UpdateCatalog.changes(fromReleaseBody: body) == "• 주소창 클릭 수정\n• 링크 정리")
        #expect(UpdateCatalog.changes(fromReleaseBody: "##변경사항##\n- 본문\n## 확인\n검증") == "• 본문")
        #expect(UpdateCatalog.changes(fromReleaseBody: "- first\n- second\n\ntrailing text") == "• first\n• second")
        #expect(UpdateCatalog.changes(fromReleaseBody: "## 설치\n다운로드 안내") == "")
        #expect(UpdateCatalog.changes(fromReleaseBody: nil) == "")

        let history = [
            release("v0.3", body: "## 변경사항\n- future"),
            release("v0.2.1", body: "## 변경사항\n- newest"),
            release("v0.2.1", body: "## 변경사항\n- duplicate"),
            release("v0.2.0.1", body: "## 변경사항\n- preview", prerelease: true),
            release("v0.2", body: "## 변경사항\n- middle"),
            release("v0.1.5", body: "## 변경사항\n- draft", draft: true),
            release("v0.1.2", body: nil),
            release("v0.1.1", body: "## 변경사항\n- installed")
        ]
        let notes = UpdateCatalog.pendingNotes(
            from: history, current: try #require(AppVersion("0.1.1")), latest: try #require(AppVersion("0.2.1")),
            versionHeading: { "v\($0)" }, emptyText: "(none)"
        )
        #expect(notes == "v0.2.1\n• newest\n\nv0.2\n• middle\n\nv0.1.2\n(none)")
    }

    @Test("GitHub release JSON decodes with the fields the updater relies on")
    func decoding() throws {
        let json = """
        {"tag_name":"v0.1.2","body":"## 변경사항\\n- a","draft":false,"prerelease":false,
         "html_url":"https://github.com/RilakKuma2/Mac_file_explorer/releases/tag/v0.1.2",
         "assets":[{"name":"Mac-Explorer-0.1.2-arm64.dmg","size":1,
           "browser_download_url":"https://github.com/RilakKuma2/Mac_file_explorer/releases/download/v0.1.2/Mac-Explorer-0.1.2-arm64.dmg"}]}
        """
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(decoded.tagName == "v0.1.2")
        #expect(decoded.assets?.first?.name == "Mac-Explorer-0.1.2-arm64.dmg")
    }

    @Test("The helper restores the previous bundle when the swap cannot complete")
    func applyScriptSwapsAndRollsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerUpdateTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Installed/App.app", isDirectory: true)
        let source = root.appendingPathComponent("Image/App.app", isDirectory: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        for directory in [installed, source, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "old".write(to: installed.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try "new".write(to: source.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        // Stub out the tools that would touch the real system.
        let script = UpdateInstaller.applyScript
            .replacingOccurrences(of: "/usr/bin/hdiutil", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")
        let scriptURL = root.appendingPathComponent("apply.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        func run(source: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // PID 1 never exits from our point of view, so use a finished one.
            let finished = Process()
            finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try finished.run(); finished.waitUntilExit()
            process.arguments = [scriptURL.path, installed.path, source.path,
                                 root.appendingPathComponent("mnt").path, staging.path,
                                 String(finished.processIdentifier)]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }

        try run(source: root.appendingPathComponent("Image/Missing.app"))
        #expect(try String(contentsOf: installed.appendingPathComponent("version")) == "old")

        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run(source: source)
        #expect(try String(contentsOf: installed.appendingPathComponent("version")) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(leftovers == ["App.app"])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("Queued mutations keep restart blocked until completion")
    @MainActor
    func mutationBlocksRestart() async {
        let manager = FileOperationManager.shared
        var finished = false
        manager.performSerializedMutation({ 42 }) { result in
            if case .success(42) = result { finished = true }
        }
        #expect(manager.hasActiveOperations)
        for _ in 0..<200 {
            if finished { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(finished)
    }
}
