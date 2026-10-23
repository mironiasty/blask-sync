import AppKit
import HueKit
import Observation
import SwiftUI

/// Manual control of one entertainment area over the streaming API.
@MainActor
@Observable
final class LightControl {
    enum StreamState: Equatable {
        case stopped, starting, streaming, stopping
    }

    let area: EntertainmentArea
    private(set) var state: StreamState = .stopped
    /// Light names per channel, e.g. "Desk lamp" or "Gradient strip, TV light".
    private(set) var channelNames: [UInt8: String] = [:]
    /// Base color per channel; `brightness` is applied on top when sending.
    private(set) var colors: [UInt8: LightColor]
    var brightness = 1.0 {
        didSet { pushColors() }
    }
    var errorMessage: String?

    private let credentials: BridgeCredentials
    private var stream: EntertainmentStream?

    init(area: EntertainmentArea, credentials: BridgeCredentials) {
        self.area = area
        self.credentials = credentials
        colors = Dictionary(uniqueKeysWithValues: area.channels.map { ($0.id, LightColor.white) })
    }

    func loadChannelNames() async {
        guard channelNames.isEmpty else { return }
        do {
            let names = try await BridgeClient(credentials: credentials)
                .entertainmentServiceNames(applicationKey: credentials.applicationKey)
            channelNames = Dictionary(uniqueKeysWithValues: area.channels.map { channel in
                var seen = Set<String>()
                let lights = channel.serviceIds.compactMap { names[$0] }.filter { seen.insert($0).inserted }
                return (channel.id, lights.joined(separator: ", "))
            })
        } catch {
            errorMessage = error.localizedDescription
        }
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
        colors.mapValues { $0.scaled(by: brightness) }
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
