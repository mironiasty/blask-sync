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
                    LegendItem(symbol: nil, text: "Strip segment")
                    LegendItem(symbol: "lamp.table", text: "Lamp: on the screen or beside it")
                    Spacer()
                    Button("Reset Layout", action: control.resetMapping)
                }
                Text("Drag a light to move it; hover to see the screen area it follows, select it to resize that area. Lamps beside the screen follow the nearest edge, softened toward the overall screen color the further away they are.")
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
    let symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.orange.gradient)
                    .shadow(color: .orange, radius: 4)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: symbol == nil ? 10 : 16, height: symbol == nil ? 10 : 16)
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
    @State private var hovered: UInt8?

    var body: some View {
        GeometryReader { proxy in
            let geometry = CanvasGeometry(size: proxy.size)
            ZStack(alignment: .topLeading) {
                wall(geometry)
                blooms(geometry)
                monitor(geometry)
                sampleAreas(geometry)
                lampBeams(geometry)
                stripLine(geometry)
                ForEach(control.area.channels) { channel in
                    if let region = control.mapping.regions[channel.id] {
                        LightMarker(
                            color: color(for: channel.id),
                            label: label(for: channel.id),
                            symbol: control.isLamp(channel.id) ? symbol(for: channel.id) : nil,
                            isSelected: selection == channel.id,
                            region: regionBinding(channel.id, fallback: region),
                            bounds: control.placementBounds(for: channel.id),
                            geometry: geometry,
                            onSelect: { selection = channel.id },
                            onHover: { hovered = $0 ? channel.id : (hovered == channel.id ? nil : hovered) }
                        )
                        .zIndex(selection == channel.id ? 2 : 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .aspectRatio(control.selectedDisplay?.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(minHeight: 300)
    }

    // MARK: Scene

    private func wall(_ geometry: CanvasGeometry) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(RadialGradient(
                colors: [Color(white: 0.16), Color(white: 0.07)],
                center: .center, startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.7
            ))
            .frame(width: geometry.size.width, height: geometry.size.height)
    }

    /// Each light's color spilling onto the wall, so the canvas reads as a lit room.
    private func blooms(_ geometry: CanvasGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(control.area.channels) { channel in
                if let region = control.mapping.regions[channel.id] {
                    let diameter = geometry.size.width * (control.isLamp(channel.id) ? 0.42 : 0.2)
                    let center = geometry.point(x: region.centerX, y: region.centerY)
                    Circle()
                        .fill(RadialGradient(colors: [color(for: channel.id).opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: diameter / 2))
                        .frame(width: diameter, height: diameter)
                        .offset(x: center.x - diameter / 2, y: center.y - diameter / 2)
                }
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private func monitor(_ geometry: CanvasGeometry) -> some View {
        let screen = geometry.screen
        let bezel = screen.insetBy(dx: -screen.width * 0.015, dy: -screen.width * 0.015)
        let neck = CGRect(x: screen.midX - screen.width * 0.035, y: bezel.maxY, width: screen.width * 0.07, height: geometry.unit.height * 0.13)
        let foot = CGRect(x: screen.midX - screen.width * 0.13, y: neck.maxY - 2, width: screen.width * 0.26, height: geometry.unit.height * 0.035)
        return ZStack(alignment: .topLeading) {
            ForEach([neck, foot], id: \.minY) { part in
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                    .frame(width: part.width, height: part.height)
                    .offset(x: part.minX, y: part.minY)
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.09))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 12, y: 6)
                .frame(width: bezel.width, height: bezel.height)
                .offset(x: bezel.minX, y: bezel.minY)
            Group {
                if let preview = control.preview {
                    Image(decorative: preview, scale: 1).resizable()
                } else {
                    LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(
                            Label(control.pausedForApp == nil ? "Screen preview" : "Paused while \(control.pausedForApp!) is in front", systemImage: "display")
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.45))
                        )
                }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                // Glass sheen.
                LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            )
            .offset(x: screen.minX, y: screen.minY)
        }
        .allowsHitTesting(false)
    }

    /// The screen area of the hovered and selected lights; the selected one can be resized.
    private func sampleAreas(_ geometry: CanvasGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Set([hovered, selection].compactMap { $0 })), id: \.self) { channel in
                if let region = control.mapping.regions[channel] {
                    SampleArea(
                        color: color(for: channel),
                        isSelected: selection == channel,
                        region: regionBinding(channel, fallback: region),
                        bounds: control.placementBounds(for: channel),
                        geometry: geometry
                    )
                }
            }
        }
    }

    /// Lamps beside the screen: a faint dotted link to their area, a soft beam when hovered or selected.
    private func lampBeams(_ geometry: CanvasGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(control.area.channels) { channel in
                if let region = control.mapping.regions[channel.id], region.distanceFromScreen > 0 {
                    let sampled = region.sampledRegion
                    let from = geometry.point(x: region.centerX, y: region.centerY)
                    let to = geometry.point(x: sampled.centerX, y: sampled.centerY)
                    let active = selection == channel.id || hovered == channel.id
                    Path { path in
                        path.move(to: from)
                        path.addLine(to: to)
                    }
                    .stroke(
                        LinearGradient(colors: [color(for: channel.id).opacity(active ? 0.9 : 0.35), color(for: channel.id).opacity(0.1)], startPoint: UnitPoint(x: from.x / geometry.size.width, y: from.y / geometry.size.height), endPoint: UnitPoint(x: to.x / geometry.size.width, y: to.y / geometry.size.height)),
                        style: StrokeStyle(lineWidth: active ? 6 : 1.5, lineCap: .round, dash: active ? [] : [2, 4])
                    )
                    .blur(radius: active ? 2 : 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The LED strip: a glowing line through its segments, colored segment by segment.
    private func stripLine(_ geometry: CanvasGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(control.strips, id: \.light) { strip in
                let points = strip.channels.compactMap { channel in
                    control.mapping.regions[channel].map { (channel, geometry.point(x: $0.centerX, y: $0.centerY)) }
                }
                ForEach(Array(zip(points, points.dropFirst()).enumerated()), id: \.offset) { _, pair in
                    let (a, b) = pair
                    let gradient = LinearGradient(
                        colors: [color(for: a.0), color(for: b.0)],
                        startPoint: UnitPoint(x: a.1.x / geometry.size.width, y: a.1.y / geometry.size.height),
                        endPoint: UnitPoint(x: b.1.x / geometry.size.width, y: b.1.y / geometry.size.height)
                    )
                    let segment = Path { path in
                        path.move(to: a.1)
                        path.addLine(to: b.1)
                    }
                    segment.stroke(gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round)).blur(radius: 5).opacity(0.8)
                    segment.stroke(gradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Helpers

    /// The color the light sends now; a palette placeholder when nothing is live, so it never looks dead.
    private func color(for channel: UInt8) -> Color {
        if let live = control.liveColors[channel] {
            return live.fullBrightness.color
        }
        let index = control.area.channels.firstIndex { $0.id == channel } ?? 0
        return MusicPalette.vivid.color(at: Double(index) * 0.7).color
    }

    private func label(for channelId: UInt8) -> String {
        guard let description = control.channelDescriptions[channelId] else { return "\(channelId)" }
        if case .stripSegment(let index, _) = description.kind { return "\(index + 1)" }
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

/// A light on the canvas: a glowing dot (strip segment) or bulb (lamp) at its region's center.
/// Dragging it moves the region.
private struct LightMarker: View {
    let color: Color
    let label: String
    let symbol: String?
    let isSelected: Bool
    @Binding var region: ScreenRegion
    let bounds: ScreenRegion.Bounds
    let geometry: CanvasGeometry
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    @State private var dragStart: ScreenRegion?

    var body: some View {
        let size: CGFloat = symbol == nil ? 22 : 36
        let center = geometry.point(x: region.centerX, y: region.centerY)
        ZStack {
            Circle()
                .fill(color.gradient)
                .shadow(color: color, radius: isSelected ? 12 : 7)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            } else {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(isSelected ? 1 : 0.7), lineWidth: isSelected ? 3 : 1.5))
        .overlay {
            if isSelected {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-5)
            }
        }
        .contentShape(Circle().inset(by: -6))
        .onHover(perform: onHover)
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = region
                        onSelect()
                    }
                    guard let dragStart else { return }
                    region = dragStart.moved(
                        dx: value.translation.width / geometry.unit.width,
                        dy: value.translation.height / geometry.unit.height,
                        within: bounds
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
        .position(center)
    }
}

/// The screen area a light follows, shown on hover and selection; the selected one gets a resize handle.
private struct SampleArea: View {
    let color: Color
    let isSelected: Bool
    @Binding var region: ScreenRegion
    let bounds: ScreenRegion.Bounds
    let geometry: CanvasGeometry

    @State private var resizeStart: ScreenRegion?

    var body: some View {
        let rect = geometry.rect(region.sampledRegion)
        RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .shadow(color: color.opacity(0.6), radius: 8)
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white))
                        .shadow(radius: 2)
                        .offset(x: 7, y: 7)
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
                        .help("Drag to resize the area this light follows")
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(isSelected)
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
                        Toggle("Pause for Apple TV app", isOn: $control.pauseForProtectedApps)
                        Text("macOS hides protected movies while the screen is captured. With this on, capture pauses while the Apple TV app is in front and the lights glow softly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
