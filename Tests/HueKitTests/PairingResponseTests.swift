import Foundation
import Testing
@testable import HueKit

struct PairingResponseTests {
    @Test func success() throws {
        let json = #"[{"success":{"username":"abc123","clientkey":"0123456789ABCDEF0123456789ABCDEF"}}]"#
        let result = try BridgeClient.parsePairingResponse(Data(json.utf8))
        #expect(result == .success(applicationKey: "abc123", clientKey: "0123456789ABCDEF0123456789ABCDEF"))
    }

    @Test func linkButtonNotPressed() throws {
        let json = #"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#
        #expect(try BridgeClient.parsePairingResponse(Data(json.utf8)) == .linkButtonNotPressed)
    }

    @Test func otherErrorThrows() {
        let json = #"[{"error":{"type":7,"address":"/devicetype","description":"invalid value"}}]"#
        #expect(throws: HueError.bridge(type: 7, description: "invalid value")) {
            try BridgeClient.parsePairingResponse(Data(json.utf8))
        }
    }

    @Test func missingClientKeyThrows() {
        let json = #"[{"success":{"username":"abc123"}}]"#
        #expect(throws: HueError.missingClientKey) {
            try BridgeClient.parsePairingResponse(Data(json.utf8))
        }
    }

    @Test func decodesEntertainmentArea() throws {
        let json = #"""
        {"id":"1a2b","type":"entertainment_configuration","metadata":{"name":"Desk"},
         "configuration_type":"screen","status":"inactive",
         "channels":[{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[]},
                     {"channel_id":1,"position":{"x":1,"y":0,"z":0},"members":[]}]}
        """#
        let area = try JSONDecoder().decode(EntertainmentArea.self, from: Data(json.utf8))
        #expect(area.name == "Desk")
        #expect(area.configurationType == "screen")
        #expect(area.channelCount == 2)
    }
}
