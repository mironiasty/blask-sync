import HueKit
import SwiftUI
import SyncCore

/// Settings → Screen: a canvas of the screen and the wall around it, where each channel's region is
/// dragged into place, plus an inspector with capture and color settings.
struct ScreenMappingView: View {
    @Bindable var control: LightControl
    @State private var selection: UInt8?
    @State private var identifying = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CaptureStatusBanner(control: control)
                MappingCanvas(control: control, selection: $selection)
                HStack(spacing: 16) {
                    LegendItem(color: .accentColor, dashed: false, text: "Strip segment")
                    LegendItem(color: .orange, dashed: true, text: "Lamp: on the screen or beside it")
                    Spacer()
                    Button("Reset Layout", action: control.resetMapping)
                }
                Text("Drag a region to move it, drag its corner to resize. Lamps beside the screen follow the nearest edge, softened toward the overall screen color the further away they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Inspector(control: control, selection: $selection, identifying: $identifying)
                .frame(width: 280)
        }
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

private struct LegendItem: View {
    let color: Color
    let dashed: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 16, height: 12)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Canvas

/// Maps screen coordinates (screen = 0...1, wall = the margin around it) to canvas points.
private struct CanvasGeometry {
    let size: CGSize

    private var margin: Double { ScreenRegion.surroundingsMargin }
    private var span: Double { 1 + 2 * margin }

    /// Canvas points per screen width/height.
    var unit: CGSize { CGSize(width: size.width / span, height: size.height / span) }

    func rect(_ region: ScreenRegion) -> CGRect {
        CGRect(
            x: (region.x + margin) * unit.width,
            y: (region.y + margin) * unit.height,
            width: region.width * unit.width,
            height: region.height * unit.height
        )
    }

    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: (x + margin) * unit.width, y: (y + margin) * unit.height)
    }

    var screen: CGRect { rect(ScreenRegion(x: 0, y: 0, width: 1, height: 1)) }
}

private struct MappingCanvas: View {
    let control: LightControl
    @Binding var selection: UInt8?

    var body: some View {
        GeometryReader { proxy in
            let geometry = CanvasGeometry(size: proxy.size)
            ZStack(alignment: .topLeading) {
                wall(geometry)
                screen(geometry)
                stripPaths(geometry)
                lampConnectors(geometry)
                selectedSampleArea(geometry)

                ForEach(control.area.channels) { channel in
                    if let region = control.mapping.regions[channel.id] {
                        RegionView(
                            label: label(for: channel.id),
                            symbol: control.isLamp(channel.id) ? symbol(for: channel.id) : nil,
                            isStrip: !control.isLamp(channel.id),
                            liveColor: control.liveColors[channel.id]?.color,
                            isSelected: selection == channel.id,
                            region: regionBinding(channel.id, fallback: region),
                            bounds: control.placementBounds(for: channel.id),
                            geometry: geometry,
                            onSelect: { selection = channel.id }
                        )
                        .zIndex(selection == channel.id ? 1 : 0)
                    }
                }
            }
        }
        .aspectRatio(control.selectedDisplay?.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(minHeight: 300)
    }

    private func wall(_ geometry: CanvasGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(white: 0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                )
            Text("Wall")
                .font(.caption)
                .foregroundStyle(Color(white: 0.5))
                .padding(8)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private func screen(_ geometry: CanvasGeometry) -> some View {
        let rect = geometry.screen
        return ZStack(alignment: .topLeading) {
            // Monitor stand, for orientation.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.28))
                .frame(width: rect.width * 0.08, height: geometry.unit.height * 0.12)
                .offset(x: rect.midX - rect.width * 0.04, y: rect.maxY)
            Group {
                if let preview = control.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                } else {
                    LinearGradient(colors: [Color(white: 0.1), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                        .overlay(Text("Screen").font(.caption).foregroundStyle(Color(white: 0.45)))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(white: 0.45), lineWidth: 2))
            .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// Strip segments joined in physical order, so the strip's run around the screen is visible.
    private func stripPaths(_ geometry: CanvasGeometry) -> some View {
        ForEach(control.strips, id: \.light) { strip in
            Path { path in
                let points = strip.channels.compactMap { control.mapping.regions[$0] }
                    .map { geometry.point(x: $0.centerX, y: $0.centerY) }
                guard let first = points.first else { return }
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        }
    }

    /// A line from each lamp beside the screen to the screen area it samples.
    private func lampConnectors(_ geometry: CanvasGeometry) -> some View {
        Path { path in
            for (_, region) in control.mapping.regions where region.distanceFromScreen > 0 {
                let sampled = region.sampledRegion
                path.move(to: geometry.point(x: region.centerX, y: region.centerY))
                path.addLine(to: geometry.point(x: sampled.centerX, y: sampled.centerY))
            }
        }
        .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
    }

    @ViewBuilder
    private func selectedSampleArea(_ geometry: CanvasGeometry) -> some View {
        if let selection, let region = control.mapping.regions[selection], region.distanceFromScreen > 0 {
            let rect = geometry.rect(region.sampledRegion)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func label(for channelId: UInt8) -> String {
        guard let description = control.channelDescriptions[channelId] else { return "\(channelId)" }
        if case .stripSegment(let index, _) = description.kind { return "S\(index + 1)" }
        return "\(channelId)"
    }

    private func symbol(for channelId: UInt8) -> String {
        LightSymbol.name(for: control.channelDescriptions[channelId]?.lights.first?.archetype)
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
    /// Light icon, shown for lamps.
    let symbol: String?
    let isStrip: Bool
    /// The color this channel currently sends, shown as a swatch while screen sync runs.
    let liveColor: Color?
    let isSelected: Bool
    @Binding var region: ScreenRegion
    let bounds: ScreenRegion.Bounds
    let geometry: CanvasGeometry
    let onSelect: () -> Void

    @State private var moveStart: ScreenRegion?
    @State private var resizeStart: ScreenRegion?

    private var tint: Color { isStrip ? .accentColor : .orange }

    var body: some View {
        let frame = geometry.rect(region)
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(isSelected ? 0.45 : 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isStrip ? [] : [4, 3]))
            )
            .overlay { content }
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
                            dx: value.translation.width / geometry.unit.width,
                            dy: value.translation.height / geometry.unit.height,
                            within: bounds
                        )
                    }
                    .onEnded { _ in moveStart = nil }
            )
            .offset(x: frame.minX, y: frame.minY)
    }

    private var content: some View {
        VStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
            }
            HStack(spacing: 4) {
                if let liveColor {
                    Circle()
                        .fill(liveColor)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8)))
                        .frame(width: 10, height: 10)
                }
                Text(label)
                    .font(.caption.bold())
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
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
                            dWidth: value.translation.width / geometry.unit.width,
                            dHeight: value.translation.height / geometry.unit.height,
                            within: bounds
                        )
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }
}

// MARK: Inspector

private struct Inspector: View {
    @Bindable var control: LightControl
    @Binding var selection: UInt8?
    @Binding var identifying: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Display", selection: $control.selectedDisplayID) {
                            ForEach(control.displays) { display in
                                Text(display.name).tag(display.id)
                            }
                        }
                        Picker("Intensity", selection: $control.intensity) {
                            ForEach(SyncIntensity.allCases, id: \.self) { intensity in
                                Text(intensity.rawValue.capitalized).tag(intensity)
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Color") {
                    VStack(alignment: .leading, spacing: 10) {
                        PercentSlider(title: "Brightness", value: $control.brightness, range: 0...1)
                        PercentSlider(title: "Saturation boost", value: $control.saturationBoost, range: 0...1)
                            .help("Makes averaged screen colors more vivid.")
                        PercentSlider(title: "Minimum brightness", value: $control.minimumBrightness, range: 0...0.3)
                            .help("Keeps the lights glowing faintly in dark scenes instead of switching off.")
                    }
                    .padding(4)
                }

                GroupBox("Channels") {
                    ChannelList(control: control, selection: $selection)
                        .frame(height: 190)
                }

                GroupBox("Selected Channel") {
                    SelectedChannelDetails(control: control, selection: selection, identifying: $identifying)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct SelectedChannelDetails: View {
    let control: LightControl
    let selection: UInt8?
    @Binding var identifying: Bool

    var body: some View {
        if let selection, let region = control.mapping.regions[selection] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol(selection))
                        .foregroundStyle(.secondary)
                    Text(title(selection)).bold()
                    Spacer()
                    if let color = control.liveColors[selection]?.color {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
                            .frame(width: 28, height: 18)
                            .help("Current color")
                    }
                }
                Text(explanation(selection, region))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Identify in the room", isOn: $identifying)
                    .disabled(control.state != .streaming)
                    .help("Lights only this channel, in white, so you can find it. Requires sync to be running.")
            }
        } else {
            Text("Select a channel on the canvas or in the list.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ channelId: UInt8) -> String {
        guard let description = control.channelDescriptions[channelId] else { return "Channel \(channelId)" }
        if case .stripSegment(let index, _) = description.kind {
            return "Segment \(index + 1) · \(description.strip?.name ?? "")"
        }
        return description.name.nilIfEmpty ?? "Channel \(channelId)"
    }

    private func symbol(_ channelId: UInt8) -> String {
        control.isLamp(channelId)
            ? LightSymbol.name(for: control.channelDescriptions[channelId]?.lights.first?.archetype)
            : "light.strip.2"
    }

    private func explanation(_ channelId: UInt8, _ region: ScreenRegion) -> String {
        guard control.isLamp(channelId) else {
            return "Gradient strip segment. Follows the screen area under it."
        }
        guard region.distanceFromScreen > 0 else {
            return "Lamp on the screen. Follows the area under it. Drag it onto the wall if it stands beside the screen."
        }
        let blend = Int((region.ambientBlend * 100).rounded())
        return "Lamp beside the screen. Follows the nearest screen area (outlined), mixed with \(blend)% of the overall screen color."
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
