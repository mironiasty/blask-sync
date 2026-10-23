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
        #expect(area.channels.map(\.id) == [0, 1])
        #expect(area.channels[1].position.x == 1)
        #expect(area.lightIds.isEmpty, "light_services is optional")
    }
}

struct ChannelDescriptionTests {
    let strip = EntertainmentLight(serviceId: "strip", name: "Za monitorem", archetype: "hue_lightstrip_pc", segmentCount: 7)
    let lamp = EntertainmentLight(serviceId: "lamp", name: "Lampka stołowa", archetype: "table_shade", segmentCount: 1)
    let origin = EntertainmentArea.Channel.Position(x: 0, y: 0, z: 0)

    @Test func segmentOfGradientStrip() {
        let channel = EntertainmentArea.Channel(id: 3, position: origin, members: [.init(serviceId: "strip", index: 3)])
        let description = ChannelDescription(channel: channel, lights: ["strip": strip, "lamp": lamp])
        #expect(description.kind == .stripSegment(index: 3, count: 7))
        #expect(description.strip == strip)
        #expect(description.name == "Za monitorem")
    }

    @Test func standaloneLamp() {
        let channel = EntertainmentArea.Channel(id: 7, position: origin, members: [.init(serviceId: "lamp", index: 0)])
        let description = ChannelDescription(channel: channel, lights: ["strip": strip, "lamp": lamp])
        #expect(description.kind == .lamp)
        #expect(description.strip == nil)
    }

    @Test func memberIndexDefaultsToZero() throws {
        let json = #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"abc","rtype":"entertainment"}}]}"#
        let channel = try JSONDecoder().decode(EntertainmentArea.Channel.self, from: Data(json.utf8))
        #expect(channel.members == [.init(serviceId: "abc", index: 0)])
    }
}

struct AreaLightServicesTests {
    @Test func decodesLightIds() throws {
        let json = #"""
        {"id":"a","metadata":{"name":"Desk"},"configuration_type":"screen","status":"inactive","channels":[],
         "light_services":[{"rid":"light-1","rtype":"light"},{"rid":"light-2","rtype":"light"}]}
        """#
        let area = try JSONDecoder().decode(EntertainmentArea.self, from: Data(json.utf8))
        #expect(area.lightIds == ["light-1", "light-2"])
    }
}
