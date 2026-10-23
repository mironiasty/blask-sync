import Foundation
import HueKit
import Testing
@testable import SyncCore

struct ScreenMappingTests {
    typealias Position = EntertainmentArea.Channel.Position

    private func isClose(_ a: ScreenRegion, _ b: ScreenRegion) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1e-9 }
    }

    @Test func cornersProjectToScreenCorners() {
        // Bottom-left of a strip running around a monitor.
        let region = ScreenMapping.defaultRegion(for: Position(x: -0.4, y: 0.8, z: -0.4))
        #expect(isClose(region, ScreenRegion(x: 0, y: 0.75, width: 0.25, height: 0.25)))
    }

    @Test func topEdgeKeepsHorizontalOrder() {
        let left = ScreenMapping.defaultRegion(for: Position(x: -0.22, y: 0.8, z: 0.4))
        let middle = ScreenMapping.defaultRegion(for: Position(x: 0, y: 0.8, z: 0.4))
        let right = ScreenMapping.defaultRegion(for: Position(x: 0.22, y: 0.8, z: 0.4))
        #expect([left.y, middle.y, right.y] == [0, 0, 0])
        #expect(left.centerX < middle.centerX && middle.centerX < right.centerX)
        #expect(abs(middle.centerX - 0.5) < 1e-9)
    }

    @Test func centeredChannelSamplesMiddle() {
        let region = ScreenMapping.defaultRegion(for: Position(x: 0, y: 1, z: 0))
        #expect(isClose(region, ScreenRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
    }

    @Test func moveAndResizeStayOnScreen() {
        let region = ScreenRegion(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        #expect(isClose(region.moved(dx: 0.5, dy: -1), ScreenRegion(x: 0.8, y: 0, width: 0.2, height: 0.2)))
        #expect(isClose(region.resized(dWidth: 1, dHeight: -1), ScreenRegion(x: 0.7, y: 0.7, width: 0.3, height: ScreenRegion.minimumSize)))
    }

    @Test func reconcileAddsAndDropsChannels() {
        let kept = ScreenRegion(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let mapping = ScreenMapping(regions: [0: kept, 9: kept])
        let channels = [
            EntertainmentArea.Channel(id: 0, position: Position(x: 0, y: 0, z: 0), members: []),
            EntertainmentArea.Channel(id: 1, position: Position(x: 1, y: 0, z: 0), members: []),
        ]
        let reconciled = mapping.reconciled(with: channels)
        #expect(reconciled.regions.keys.sorted() == [0, 1])
        #expect(reconciled.regions[0] == kept)
    }

    @Test func roundTripsThroughJSON() throws {
        let mapping = ScreenMapping(regions: [3: ScreenRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)])
        let decoded = try JSONDecoder().decode(ScreenMapping.self, from: JSONEncoder().encode(mapping))
        #expect(decoded == mapping)
    }
}
