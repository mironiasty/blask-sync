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

struct HueColorTests {
    @Test func primariesMapToKnownChromaticities() {
        // Philips' wide-gamut matrix: pure red, green, blue and white in CIE xy.
        let red = LightColor(red: 1, green: 0, blue: 0).hueState
        #expect(abs(red.x - 0.7006) < 0.001 && abs(red.y - 0.2993) < 0.001)
        let green = LightColor(red: 0, green: 1, blue: 0).hueState
        #expect(abs(green.x - 0.1724) < 0.001 && abs(green.y - 0.7468) < 0.001)
        let white = LightColor.white.hueState
        #expect(abs(white.x - 0.3227) < 0.001 && abs(white.y - 0.329) < 0.001)
    }

    @Test func brightnessIsTheBrightestComponentAndKeepsChromaticity() {
        let dim = LightColor(red: 0.5, green: 0, blue: 0).hueState
        let full = LightColor(red: 1, green: 0, blue: 0).hueState
        #expect(dim.brightness == 0.5)
        #expect(abs(dim.x - full.x) < 1e-9 && abs(dim.y - full.y) < 1e-9)
        #expect(LightColor.black.hueState.brightness == 0)
    }

    @Test func gradientSamplesSpreadEvenly() {
        #expect(BridgeClient.gradientSamples(Array(0..<7), count: 5) == [0, 2, 3, 5, 6])
        #expect(BridgeClient.gradientSamples(Array(0..<3), count: 5) == [0, 1, 2])
    }
}
