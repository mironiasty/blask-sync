import HueKit
import SwiftUI
import SyncCore

/// Screen sync settings plus an editor for which part of the screen each channel samples:
/// drag regions to move, drag a corner to resize.
struct ScreenMappingView: View {
    @Bindable var control: LightControl
    @State private var selection: UInt8?
    @State private var identifying = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Display", selection: $control.selectedDisplayID) {
                        ForEach(control.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    LabeledContent("Brightness") {
                        Slider(value: $control.brightness, in: 0...1)
                            .frame(width: 120)
                    }
                    Picker("Intensity", selection: $control.intensity) {
                        ForEach(SyncIntensity.allCases, id: \.self) { intensity in
                            Text(intensity.rawValue.capitalized).tag(intensity)
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 20) {
                    LabeledContent("Saturation") {
                        Slider(value: $control.saturationBoost, in: 0...1)
                            .frame(width: 140)
                    }
                    .help("Makes averaged screen colors more vivid.")
                    LabeledContent("Minimum brightness") {
                        Slider(value: $control.minimumBrightness, in: 0...0.3)
                            .frame(width: 140)
                    }
                    .help("Keeps the lights glowing faintly in dark scenes instead of switching off.")
                    Spacer()
                }
                CaptureStatusBanner(control: control)
                ScreenCanvas(control: control, selection: $selection)
                HStack {
                    Text("Drag a region to move it, drag its corner to resize.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults", action: control.resetMapping)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                ChannelList(control: control, selection: $selection)
                Toggle("Identify selected channel", isOn: $identifying)
                    .disabled(control.state != .streaming || selection == nil)
                    .help("Lights only the selected channel, in white, so you can find it in the room. Requires streaming.")
            }
            .frame(width: 240)
        }
        .padding(.top, 8)
        .onChange(of: selection) { updateIdentify() }
        .onChange(of: identifying) { updateIdentify() }
        .onChange(of: control.state) {
            if control.state != .streaming { identifying = false }
        }
        .onDisappear { control.identifiedChannel = nil }
    }

    private func updateIdentify() {
        control.identifiedChannel = identifying ? selection : nil
    }
}

// MARK: Canvas

private struct ScreenCanvas: View {
    @Bindable var control: LightControl
    @Binding var selection: UInt8?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let preview = control.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.35), lineWidth: 2))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.35), lineWidth: 2))
                    Text("Screen")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.45))
                        .frame(width: size.width, height: size.height)
                }

                // Strip segments in physical order, so the strip's run around the screen is visible.
                ForEach(control.strips, id: \.light) { strip in
                    Path { path in
                        let points = strip.channels.compactMap { control.mapping.regions[$0] }
                            .map { CGPoint(x: $0.centerX * size.width, y: $0.centerY * size.height) }
                        guard let first = points.first else { return }
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                }

                ForEach(control.area.channels) { channel in
                    if let region = control.mapping.regions[channel.id] {
                        RegionView(
                            label: label(for: channel.id),
                            isStrip: control.channelDescriptions[channel.id]?.strip != nil,
                            liveColor: control.liveColors[channel.id]?.color,
                            isSelected: selection == channel.id,
                            region: regionBinding(channel.id, fallback: region),
                            canvasSize: size,
                            onSelect: { selection = channel.id }
                        )
                        .zIndex(selection == channel.id ? 1 : 0)
                    }
                }
            }
        }
        .aspectRatio(control.selectedDisplay?.aspectRatio ?? 16 / 9, contentMode: .fit)
    }

    private func label(for channelId: UInt8) -> String {
        guard let description = control.channelDescriptions[channelId] else { return "\(channelId)" }
        if case .stripSegment(let index, _) = description.kind { return "S\(index + 1)" }
        return "\(channelId)"
    }

    private func regionBinding(_ channelId: UInt8, fallback: ScreenRegion) -> Binding<ScreenRegion> {
        Binding(
            get: { control.mapping.regions[channelId] ?? fallback },
            set: { control.mapping.regions[channelId] = $0 }
        )
    }
}

private struct RegionView: View {
    let label: String
    let isStrip: Bool
    /// The color this channel currently sends, shown as a swatch while screen sync runs.
    let liveColor: Color?
    let isSelected: Bool
    @Binding var region: ScreenRegion
    let canvasSize: CGSize
    let onSelect: () -> Void

    @State private var moveStart: ScreenRegion?
    @State private var resizeStart: ScreenRegion?

    private var tint: Color { isStrip ? .accentColor : .orange }

    var body: some View {
        let frame = CGRect(
            x: region.x * canvasSize.width,
            y: region.y * canvasSize.height,
            width: region.width * canvasSize.width,
            height: region.height * canvasSize.height
        )
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(isSelected ? 0.45 : 0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isStrip ? [] : [4, 3]))
            )
            .overlay {
                HStack(spacing: 4) {
                    if let liveColor {
                        Circle()
                            .fill(liveColor)
                            .overlay(Circle().strokeBorder(.white.opacity(0.8)))
                            .frame(width: 12, height: 12)
                    }
                    Text(label)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected { resizeHandle }
            }
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if moveStart == nil {
                            moveStart = region
                            onSelect()
                        }
                        guard let moveStart else { return }
                        region = moveStart.moved(
                            dx: value.translation.width / canvasSize.width,
                            dy: value.translation.height / canvasSize.height
                        )
                    }
                    .onEnded { _ in moveStart = nil }
            )
            .offset(x: frame.minX, y: frame.minY)
    }

    private var resizeHandle: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: 2))
            .frame(width: 12, height: 12)
            .offset(x: 4, y: 4)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = region }
                        guard let resizeStart else { return }
                        region = resizeStart.resized(
                            dWidth: value.translation.width / canvasSize.width,
                            dHeight: value.translation.height / canvasSize.height
                        )
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }
}

// MARK: Channel list

private struct ChannelList: View {
    let control: LightControl
    @Binding var selection: UInt8?

    var body: some View {
        List(selection: $selection) {
            ForEach(control.strips, id: \.light) { strip in
                Section("\(strip.light.name) · \(strip.channels.count) segments") {
                    ForEach(Array(strip.channels.enumerated()), id: \.element) { index, channelId in
                        Label("Segment \(index + 1)", systemImage: "light.strip.2")
                            .tag(channelId)
                    }
                }
            }
            Section("Lamps") {
                ForEach(control.lampChannels, id: \.self) { channelId in
                    let description = control.channelDescriptions[channelId]
                    Label(
                        description?.name.nilIfEmpty ?? "Channel \(channelId)",
                        systemImage: LightSymbol.name(for: description?.lights.first?.archetype)
                    )
                    .tag(channelId)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minHeight: 260)
    }
}

// MARK: Capture status

/// Explains why screen capture isn't running, with a way to fix it.
struct CaptureStatusBanner: View {
    let control: LightControl
    /// Stacks the buttons under the message, for narrow spaces like the menu bar panel.
    var compact = false

    var body: some View {
        switch control.captureState {
        case .idle, .capturing:
            EmptyView()
        case .needsPermission:
            banner(
                "Blask Sync needs Screen Recording permission to sample your screen.",
                detail: "After allowing it in System Settings, relaunch the app."
            ) {
                Button("Grant Access…", action: control.requestScreenPermission)
                Button("Relaunch", action: control.relaunch)
            }
        case .failed(let message):
            banner(message, detail: nil) { EmptyView() }
        }
    }

    private func banner(_ message: String, detail: String?, @ViewBuilder actions: () -> some View) -> some View {
        let text = HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    text
                    HStack { actions() }
                }
            } else {
                HStack(alignment: .top) {
                    text
                    actions()
                }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
