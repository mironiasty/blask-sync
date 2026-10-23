import AppKit
import HueKit
import Observation
import SwiftUI
import SyncCore

/// Manual control and screen mapping of one entertainment area, driven over the streaming API.
@MainActor
@Observable
final class LightControl {
    enum StreamState: Equatable {
        case stopped, starting, streaming, stopping
    }

    let area: EntertainmentArea
    private(set) var state: StreamState = .stopped
    /// What renders each channel (lamp or strip segment); empty until `loadLights()` finishes.
    private(set) var channelDescriptions: [UInt8: ChannelDescription] = [:]
    /// Base color per channel; `brightness` is applied on top when sending.
    private(set) var colors: [UInt8: LightColor]
    var brightness = 1.0 {
        didSet { pushColors() }
    }
    /// Screen region each channel samples in screen sync. Saved per area.
    var mapping: ScreenMapping {
        didSet { mappingStore.save(mapping, areaId: area.id) }
    }
    /// While set, this channel shines white and all others go dark, to find it in the room.
    var identifiedChannel: UInt8? {
        didSet { pushColors() }
    }
    var errorMessage: String?

    private let credentials: BridgeCredentials
    private let mappingStore = ScreenMappingStore()
    private var stream: EntertainmentStream?

    init(area: EntertainmentArea, credentials: BridgeCredentials) {
        self.area = area
        self.credentials = credentials
        colors = Dictionary(uniqueKeysWithValues: area.channels.map { ($0.id, LightColor.white) })
        mapping = (mappingStore.load(areaId: area.id) ?? .defaults(for: area.channels)).reconciled(with: area.channels)
    }

    func loadLights() async {
        guard channelDescriptions.isEmpty else { return }
        do {
            let lights = try await BridgeClient(credentials: credentials)
                .entertainmentLights(applicationKey: credentials.applicationKey)
            channelDescriptions = Dictionary(uniqueKeysWithValues: area.channels.map {
                ($0.id, ChannelDescription(channel: $0, lights: lights))
            })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Gradient strips in the area, each with its channels in segment order.
    var strips: [(light: EntertainmentLight, channels: [UInt8])] {
        let segments = channelDescriptions.values.compactMap { description -> (EntertainmentLight, Int, UInt8)? in
            guard let strip = description.strip, case .stripSegment(let index, _) = description.kind else { return nil }
            return (strip, index, description.channelId)
        }
        return Dictionary(grouping: segments, by: { $0.0 })
            .map { light, segments in (light, segments.sorted { $0.1 < $1.1 }.map(\.2)) }
            .sorted { $0.light.name < $1.light.name }
    }

    /// Channels rendered by standalone lights, or every channel while light info is still loading.
    var lampChannels: [UInt8] {
        area.channels.map(\.id).filter { channelDescriptions[$0]?.strip == nil }
    }

    func resetMapping() {
        mapping = .defaults(for: area.channels)
    }

    func setColor(_ color: LightColor, channel: UInt8) {
        colors[channel] = color
        pushColors()
    }

    func setAllColors(_ color: LightColor) {
        for channel in colors.keys { colors[channel] = color }
        pushColors()
    }

    func start() async {
        guard state == .stopped else { return }
        state = .starting
        errorMessage = nil
        let stream = EntertainmentStream(
            credentials: credentials,
            areaId: area.id,
            initialColors: outputColors,
            onFailure: { [weak self] error in
                Task { @MainActor in self?.streamDropped(error) }
            }
        )
        do {
            try await stream.start()
            // stop() was called while connecting (e.g. the window closed).
            guard state == .starting else {
                await stream.stop()
                state = .stopped
                return
            }
            self.stream = stream
            state = .streaming
        } catch {
            state = .stopped
            errorMessage = "Couldn't start streaming: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let stream else {
            // Still connecting: start() sees this and tears the stream down once it's up.
            if state == .starting { state = .stopping }
            return
        }
        self.stream = nil
        state = .stopping
        await stream.stop()
        state = .stopped
    }

    private func streamDropped(_ error: Error) {
        guard let stream else { return }
        self.stream = nil
        state = .stopped
        errorMessage = "Streaming stopped: \(error.localizedDescription)"
        Task { await stream.stop() }
    }

    private var outputColors: [UInt8: LightColor] {
        if let identifiedChannel {
            return Dictionary(uniqueKeysWithValues: colors.keys.map { ($0, $0 == identifiedChannel ? LightColor.white : .black) })
        }
        return colors.mapValues { $0.scaled(by: brightness) }
    }

    private func pushColors() {
        stream?.setColors(outputColors)
    }
}

extension LightColor {
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}
