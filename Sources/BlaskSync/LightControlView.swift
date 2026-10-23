import HueKit
import SwiftUI

/// Contents of the "Light Control" window.
struct LightControlView: View {
    static let windowId = "light-control"

    let model: AppModel

    var body: some View {
        if let control = model.lightControl {
            LightControlPanel(control: control)
                // A fresh panel (and stream state) per area.
                .id(control.area.id)
        } else {
            ContentUnavailableView(
                "No Area Selected",
                systemImage: "lightbulb.2",
                description: Text("Choose an entertainment area from the menu bar.")
            )
            .frame(width: 400, height: 300)
        }
    }
}

private struct LightControlPanel: View {
    @Bindable var control: LightControl

    private static let presets: [(name: String, color: LightColor)] = [
        ("Warm white", LightColor(red: 1, green: 0.72, blue: 0.42)),
        ("Cool white", .white),
        ("Red", LightColor(red: 1, green: 0, blue: 0)),
        ("Green", LightColor(red: 0, green: 1, blue: 0)),
        ("Blue", LightColor(red: 0, green: 0, blue: 1)),
        ("Purple", LightColor(red: 0.6, green: 0, blue: 1)),
        ("Off", .black),
    ]

    var body: some View {
        Form {
            Section {
                streamingRow
                if let error = control.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text(control.area.name).font(.title3.bold())
            } footer: {
                Text("While streaming, the bridge locks these lights to Blask Sync. They return to their previous state when you stop.")
            }

            Section("All Lights") {
                ColorPicker("Color", selection: allLightsColor, supportsOpacity: false)
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.name) { preset in
                        Button { control.setAllColors(preset.color) } label: {
                            Circle()
                                .fill(preset.color.color)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.5)))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
                LabeledContent("Brightness") {
                    Slider(value: $control.brightness, in: 0...1)
                }
            }

            Section("Channels") {
                ForEach(control.area.channels) { channel in
                    ChannelRow(
                        channel: channel,
                        lights: control.channelNames[channel.id],
                        color: channelColor(channel.id)
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .task { await control.loadChannelNames() }
        .onDisappear { Task { await control.stop() } }
    }

    private var streamingRow: some View {
        HStack {
            Circle()
                .fill(control.state == .streaming ? .green : .secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(statusText)
            Spacer()
            switch control.state {
            case .stopped:
                Button("Start Streaming") { Task { await control.start() } }
                    .buttonStyle(.borderedProminent)
            case .streaming:
                Button("Stop") { Task { await control.stop() } }
            case .starting, .stopping:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch control.state {
        case .stopped: "Not streaming"
        case .starting: "Connecting…"
        case .streaming: "Streaming"
        case .stopping: "Stopping…"
        }
    }

    private var allLightsColor: Binding<Color> {
        Binding(
            get: { control.area.channels.first.flatMap { control.colors[$0.id] }?.color ?? .white },
            set: { control.setAllColors(LightColor($0)) }
        )
    }

    private func channelColor(_ channel: UInt8) -> Binding<Color> {
        Binding(
            get: { control.colors[channel]?.color ?? .white },
            set: { control.setColor(LightColor($0), channel: channel) }
        )
    }
}

private struct ChannelRow: View {
    let channel: EntertainmentArea.Channel
    let lights: String?
    @Binding var color: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Channel \(channel.id)")
                Text(lights?.isEmpty == false ? lights! : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "x %+.2f  y %+.2f  z %+.2f", channel.position.x, channel.position.y, channel.position.z))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ColorPicker("Channel \(channel.id) color", selection: $color, supportsOpacity: false)
                .labelsHidden()
        }
    }
}
