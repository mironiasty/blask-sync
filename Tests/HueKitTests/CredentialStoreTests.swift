import Foundation
import Testing

@testable import HueKit

struct CredentialStoreTests {
    let store = CredentialStore(
        fileURL: FileManager.default.temporaryDirectory
            .appending(path: "CredentialStoreTests-\(UUID().uuidString)/BlaskSync/bridge.json"))
    let credentials = BridgeCredentials(
        bridgeId: "ABC123", host: "192.168.1.2", name: "Hue Bridge",
        applicationKey: "key", clientKey: "0123456789ABCDEF0123456789ABCDEF")

    @Test func roundTrip() throws {
        #expect(try store.load() == nil)
        try store.save(credentials)
        #expect(try store.load() == credentials)
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test func onlyTheUserCanRead() throws {
        try store.save(credentials)
        let attributes = { try FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int }
        #expect(try attributes(store.fileURL.path) == 0o600)
        #expect(try attributes(store.fileURL.deletingLastPathComponent().path) == 0o700)
        try store.delete()
    }
}
