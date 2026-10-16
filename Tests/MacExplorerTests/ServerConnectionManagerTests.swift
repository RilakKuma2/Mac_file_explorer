import Testing
@testable import MacExplorer

@Suite("ServerConnectionManager")
struct ServerConnectionManagerTests {
    @Test("Bare server names default to SMB")
    func defaultsToSMB() throws {
        let address = try ServerConnectionManager.shared.normalizedAddress("nas.local/Media")
        #expect(address == "smb://nas.local/Media")
    }

    @Test("SMB share addresses are preserved")
    func preservesSMBAddress() throws {
        let address = try ServerConnectionManager.shared.normalizedAddress("smb://192.168.1.20/share")
        #expect(address == "smb://192.168.1.20/share")
    }

    @Test("Unsupported server protocols are rejected")
    func rejectsUnsupportedProtocol() {
        #expect(throws: ServerConnectionError.self) {
            try ServerConnectionManager.shared.normalizedAddress("ssh://server.local/home")
        }
    }
}
