import Foundation
import Testing
@testable import HueKit

struct HueStreamMessageTests {
    let areaId = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"

    @Test func header() {
        let message = HueStreamMessage.encode(areaId: areaId, colors: [:])
        #expect(message.count == 52)
        #expect(String(decoding: message.prefix(9), as: UTF8.self) == "HueStream")
        #expect(Array(message[9..<16]) == [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(String(decoding: message[16..<52], as: UTF8.self) == areaId)
    }

    @Test func channelsAreSortedBigEndianAndClamped() {
        let message = HueStreamMessage.encode(areaId: areaId, colors: [
            1: LightColor(red: 0.5, green: -1, blue: 2),
            0: .white,
        ])
        #expect(message.count == 52 + 2 * 7)
        #expect(Array(message[52..<59]) == [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(Array(message[59..<66]) == [1, 0x80, 0x00, 0x00, 0x00, 0xFF, 0xFF])
    }

    @Test func capsAtTwentyChannels() {
        let colors = Dictionary(uniqueKeysWithValues: (0..<25).map { (UInt8($0), LightColor.black) })
        #expect(HueStreamMessage.encode(areaId: areaId, colors: colors).count == 52 + 20 * 7)
    }

    @Test func hexDecoding() {
        #expect(Data(hexString: "00ff10Ab") == Data([0x00, 0xFF, 0x10, 0xAB]))
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }

    @Test func rejectsMalformedClientKey() {
        let credentials = BridgeCredentials(bridgeId: "x", host: "1.2.3.4", name: nil, applicationKey: "k", clientKey: "1234")
        #expect(throws: HueError.invalidClientKey) {
            try EntertainmentStream.dtlsParameters(for: credentials)
        }
    }
}

struct FadeInTests {
    @Test func risesFromBlackToFull() {
        let fade = Duration.seconds(4)
        #expect(EntertainmentStream.fadeLevel(elapsed: .zero, duration: fade) == 0)
        #expect(EntertainmentStream.fadeLevel(elapsed: .seconds(2), duration: fade) == 0.25)
        #expect(EntertainmentStream.fadeLevel(elapsed: .seconds(4), duration: fade) == 1)
        #expect(EntertainmentStream.fadeLevel(elapsed: .seconds(9), duration: fade) == 1)
    }

    @Test func zeroDurationIsFullAtOnce() {
        #expect(EntertainmentStream.fadeLevel(elapsed: .zero, duration: .zero) == 1)
    }
}
