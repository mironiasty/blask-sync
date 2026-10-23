import HueKit
import SwiftUI
import SyncCore

/// Settings → Music: palette, intensity, brightness and live meters showing what the app hears.
struct MusicSettings: View {
    let model: AppModel

    var body: some View {
        Group {
            if let control = model.lightControl {
                MusicSettingsPane(control: control)
                    .id(control.area.id)
            } else {
                ContentUnavailableView(
                    "No Area Selected",
                    systemImage: "music.note",
                    description: Text("Pair a bridge and choose an entertainment area in General.")
                )
            }
        }
        .frame(width: 560)
        .frame(minHeight: 560)
    }
}

private struct MusicSettingsPane: View {
    @Bindable var control: LightControl

    private var styleDescription: String {
        switch control.musicStyle {
        case .flow:
            "Colors flow along the strip, faster as the music gets louder. Beats travel through it as soft waves from the middle to the ends; lamps breathe with the energy and bass. Intensity sets how lively it moves."
        case .pulse:
            "Colors step to the next palette color on every beat, with a flash. Lamps pulse with the bass. Intensity sets how hard beats hit and how fast they fade."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(control.area.name).font(.title3.bold())
                SyncStatusLabel(control: control)
                Spacer()
                if control.syncSource == .music {
                    SyncButton(control: control)
                } else {
                    Button("Sync with Music") {
                        control.syncSource = .music
                        Task { await control.startSync() }
                    }
                }
            }

            GroupBox("Listening") {
                VStack(alignment: .leading, spacing: 10) {
                    AudioMeters(control: control)
                    Text("If the meters stay still while music plays, allow Blask Sync in System Settings → Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = control.musicError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(4)
            }

            GroupBox("Look") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Style", selection: $control.musicStyle) {
                        Text("Flow").tag(MusicStyle.flow)
                        Text("Pulse").tag(MusicStyle.pulse)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Palette") {
                        HStack(spacing: 10) {
                            ForEach(MusicPalette.allCases, id: \.self) { palette in
                                PaletteButton(palette: palette, isSelected: control.musicPalette == palette) {
                                    control.musicPalette = palette
                                }
                            }
                        }
                    }
                    Picker("Intensity", selection: $control.musicIntensity) {
                        ForEach(SyncIntensity.allCases, id: \.self) { intensity in
                            Text(intensity.rawValue.capitalized).tag(intensity)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Brightness") {
                        Slider(value: $control.brightness, in: 0...1)
                    }
                    Text(styleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            Spacer(minLength: 0)
        }
        .padding()
        // Meters run only while this pane is visible (or while music sync streams).
        .onAppear { control.musicPreviewing = true }
        .onDisappear { control.musicPreviewing = false }
    }
}

private struct AudioMeters: View {
    let control: LightControl

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(meters, id: \.name) { meter in
                VStack(spacing: 4) {
                    MeterBar(value: meter.value, color: meter.color)
                        .frame(width: 28, height: 90)
                    Text(meter.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                TimelineView(.animation) { context in
                    let lit = control.lastBeat.map { context.date.timeIntervalSince($0) < 0.15 } ?? false
                    Circle()
                        .fill(lit ? Color.pink : Color.secondary.opacity(0.2))
                        .frame(width: 28, height: 28)
                        .shadow(color: lit ? .pink : .clear, radius: 8)
                }
                .frame(height: 90, alignment: .bottom)
                Text("Beat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LightPreview(colors: control.musicColors, channels: control.area.channels.map(\.id))
        }
    }

    private var meters: [(name: String, value: Double, color: Color)] {
        let features = control.audioFeatures
        return [
            ("Level", features.loudness, .white),
            ("Bass", features.bass, .pink),
            ("Mid", features.mid, .orange),
            ("High", features.high, .cyan),
        ]
    }
}

private struct MeterBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.gradient)
                    .frame(height: proxy.size.height * min(1, max(0, value)))
            }
        }
        .animation(.easeOut(duration: 0.1), value: value)
    }
}

/// The colors music sync currently sends, one dot per channel.
private struct LightPreview: View {
    let colors: [UInt8: LightColor]
    let channels: [UInt8]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(channels, id: \.self) { channel in
                    Circle()
                        .fill(colors[channel]?.color ?? Color.secondary.opacity(0.2))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                        .frame(width: 16, height: 16)
                }
            }
            Text("Lights")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PaletteButton: View {
    let palette: MusicPalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in
                        Rectangle().fill(color.color)
                    }
                }
                .frame(width: 60, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.4), lineWidth: isSelected ? 2.5 : 1)
                )
                Text(palette.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
