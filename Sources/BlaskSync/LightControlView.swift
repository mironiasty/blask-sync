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

    var body: some View {
        VStack(spacing: 0) {
            StreamingHeader(control: control)
                .padding()
            Picker("Mode", selection: $control.mode) {
                Text("Manual").tag(LightControl.Mode.manual)
                Text("Screen").tag(LightControl.Mode.screen)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                switch control.mode {
                case .manual: ColorsTab(control: control)
                case .screen: ScreenMappingView(control: control)
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 760, minHeight: 600)
        .task { await control.activate() }
        .onDisappear { Task { await control.deactivate() } }
    }
}

private struct StreamingHeader: View {
    let control: LightControl

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(control.area.name).font(.title2.bold())
                Spacer()
                Circle()
                    .fill(control.state == .streaming ? .green : .secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(statusText).foregroundStyle(.secondary)
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
            if let error = control.errorMessage {
                Text(error).foregroundStyle(.red)
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
}

// MARK: Colors tab

private struct ColorsTab: View {
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
            } header: {
                Text("All Lights")
            } footer: {
                Text("While streaming, the bridge locks these lights to Blask Sync. They return to their previous state when you stop.")
            }

            ForEach(control.strips, id: \.light) { strip in
                Section {
                    ForEach(Array(strip.channels.enumerated()), id: \.element) { index, channelId in
                        ChannelRow(
                            title: "Segment \(index + 1)",
                            symbol: "light.strip.2",
                            channel: channel(channelId),
                            color: channelColor(channelId)
                        )
                    }
                } header: {
                    Label("\(strip.light.name) · gradient strip, \(strip.channels.count) segments", systemImage: "light.strip.2")
                }
            }

            Section("Lamps") {
                ForEach(control.lampChannels, id: \.self) { channelId in
                    let description = control.channelDescriptions[channelId]
                    ChannelRow(
                        title: description?.name.nilIfEmpty ?? "Channel \(channelId)",
                        symbol: LightSymbol.name(for: description?.lights.first?.archetype),
                        channel: channel(channelId),
                        color: channelColor(channelId)
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func channel(_ id: UInt8) -> EntertainmentArea.Channel {
        control.area.channels.first { $0.id == id }!
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
    let title: String
    let symbol: String
    let channel: EntertainmentArea.Channel
    @Binding var color: Color

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Channel \(channel.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "x %+.2f  y %+.2f  z %+.2f", channel.position.x, channel.position.y, channel.position.z))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ColorPicker("\(title) color", selection: $color, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

/// SF Symbol for a Hue light archetype.
enum LightSymbol {
    static func name(for archetype: String?) -> String {
        guard let archetype else { return "lightbulb" }
        switch archetype {
        case let a where a.contains("lightstrip"): return "light.strip.2"
        case "hue_play": return "light.panel"
        case "hue_go", "table_shade", "table_wash", "christmas_tree": return "lamp.table"
        case let a where a.hasPrefix("floor"): return "lamp.floor"
        case let a where a.hasPrefix("desk"): return "lamp.desk"
        case let a where a.hasPrefix("pendant") || a.hasPrefix("ceiling"): return "lamp.ceiling"
        case "chandelier": return "chandelier"
        case "recessed_ceiling", "recessed_floor": return "light.recessed"
        default: return "lightbulb"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
