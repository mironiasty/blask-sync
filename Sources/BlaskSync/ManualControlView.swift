import HueKit
import SwiftUI

/// The "Manual Control" window. While open, the lights show the colors picked here.
struct ManualControlView: View {
    static let windowId = "manual-control"

    let model: AppModel

    var body: some View {
        if let control = model.lightControl {
            ManualControlPanel(control: control)
                .id(control.area.id)
        } else {
            ContentUnavailableView(
                "No Area Selected",
                systemImage: "lightbulb.2",
                description: Text("Choose an entertainment area in Settings.")
            )
            .frame(width: 400, height: 300)
        }
    }
}

private struct ManualControlPanel: View {
    let control: LightControl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(control.area.name).font(.title2.bold())
                SyncStatusLabel(control: control)
                Spacer()
                if control.state == .stopped {
                    Button("Resume") { Task { await control.start() } }
                }
            }
            .padding([.horizontal, .top])
            if let error = control.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            ManualColorsForm(control: control)
        }
        .frame(minWidth: 560, minHeight: 520)
        // Opening the window takes over the lights; closing hands them back.
        .task { await control.beginManual() }
        .onDisappear { Task { await control.endManual() } }
    }
}

// MARK: Shared sync controls

/// A colored dot plus what the lights are doing right now.
struct SyncStatusLabel: View {
    let control: LightControl

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch control.state {
        case .streaming where control.mode == .screen && control.pausedForApp != nil: .purple
        case .streaming: control.mode == .screen ? .green : .orange
        case .starting, .stopping: .yellow
        case .stopped: .secondary.opacity(0.5)
        }
    }

    private var text: String {
        switch control.state {
        case .streaming where control.mode == .screen && control.pausedForApp != nil:
            "Paused while \(control.pausedForApp ?? "") is in front"
        case .streaming: control.mode == .screen ? "Syncing with screen" : "Manual control"
        case .starting: "Connecting…"
        case .stopping: "Stopping…"
        case .stopped: "Off"
        }
    }
}

/// Starts or stops screen sync.
struct SyncButton: View {
    let control: LightControl
    var large = false

    var body: some View {
        switch control.state {
        case .stopped:
            Button { Task { await control.startScreenSync() } } label: {
                Label("Start Sync", systemImage: "play.fill")
                    .frame(maxWidth: large ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(large ? .large : .regular)
        case .streaming:
            Button { Task { await control.stop() } } label: {
                Label("Stop Sync", systemImage: "stop.fill")
                    .frame(maxWidth: large ? .infinity : nil)
            }
            .controlSize(large ? .large : .regular)
        case .starting, .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: large ? .infinity : nil)
        }
    }
}

// MARK: Colors

private struct ManualColorsForm: View {
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
                Text("Closing this window hands the lights back to screen sync if it was running, or releases them.")
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
