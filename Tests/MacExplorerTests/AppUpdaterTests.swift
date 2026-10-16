import Foundation
import Testing
@testable import MacExplorer

@Suite("App updater")
struct AppUpdaterTests {
    @Test("Update configuration requires signed feeds and explicit installation")
    func configuration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == "https://github.com/RilakKuma2/Mac_file_explorer/releases/latest/download/appcast.xml")
        let key = try #require(plist["SUPublicEDKey"] as? String)
        #expect(plist["CFBundleIdentifier"] as? String == "app.macexplorer.filemanager")
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUSendProfileInfo"] as? Bool == false)
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86400)
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
