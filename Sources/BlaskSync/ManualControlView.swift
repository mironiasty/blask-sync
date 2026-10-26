import HueKit
import SwiftUI
import SyncCore

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
                if control.mode == .manual {
                    if control.state == .stopped {
                        Button("Resume") { Task { await control.start() } }
                    }
                    Button {
                        Task { await control.resumeSync(control.syncSource) }
                    } label: {
                        Label(
                            control.syncSource == .screen ? "Back to Screen Sync" : "Back to Music Sync",
                            systemImage: control.syncSource == .screen ? "display" : "hifispeaker.fill"
                        )
                    }
                }
            }
            .padding([.horizontal, .top])
            if control.mode != .manual {
                // Switched away from the menu bar while this window was open.
                HStack {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text(control.mode == .screen ? "The lights are following the screen." : "The lights are following the music.")
                    Spacer()
                    Button("Take Over") { Task { await control.beginManual() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top])
            }
            if let error = control.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            ManualColorStudio(control: control)
        }
        .frame(minWidth: 820, minHeight: 560)
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
        if control.identifiedChannel != nil, control.state == .streaming { return .yellow }
        return switch control.state {
        case .streaming where control.mode == .screen && control.pausedForApp != nil: .purple
        case .streaming:
            switch control.mode {
            case .screen: .green
            case .music: .pink
            case .manual: .orange
            }
        case .starting, .stopping: .yellow
        case .stopped: .secondary.opacity(0.5)
        }
    }

    private var text: String {
        if control.identifiedChannel != nil, control.state == .streaming { return String(localized: "Identifying lights") }
        return switch control.state {
        case .streaming where control.mode == .screen && control.pausedForApp != nil:
            String(localized: "Paused while \(control.pausedForApp ?? "") is in front")
        case .streaming:
            switch control.mode {
            case .screen: String(localized: "Syncing with screen")
            case .music: String(localized: "Syncing with music")
            case .manual: String(localized: "Manual control")
            }
        case .starting: String(localized: "Connecting…")
        case .stopping: String(localized: "Stopping…")
        case .stopped: String(localized: "Off")
        }
    }
}

/// Starts or stops sync with the chosen source.
struct SyncButton: View {
    let control: LightControl
    var large = false

    var body: some View {
        switch control.state {
        case .stopped:
            Button { Task { await control.startSync() } } label: {
                Label("Start Sync", systemImage: "play.fill")
                    .frame(maxWidth: large ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(large ? .large : .regular)
        case .streaming:
            Button { Task { await control.stopSync() } } label: {
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

// MARK: Color studio

/// The Manual Control body: a color wheel with a pin per light, a lights panel to pick which lights to
/// edit, a brightness bar for them, and one-click scenes.
private struct ManualColorStudio: View {
    let control: LightControl
    /// Channels being edited; empty means all.
    @State private var selection: Set<UInt8> = []

    private var editedChannels: Set<UInt8> {
        selection.isEmpty ? Set(control.area.channels.map(\.id)) : selection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 18) {
                ColorWheel(control: control, selection: $selection, edited: editedChannels)
                    .frame(maxWidth: 380, maxHeight: 380)
                BrightnessBar(control: control, edited: editedChannels)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 20) {
                LightsPanel(control: control, selection: $selection)
                ScenesPanel(control: control)
                Text("Drag a pin on the wheel to recolor a light. With several lights selected, they turn together. Closing this window hands the lights back to sync if it was running, or releases them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(width: 300)
        }
        .padding(20)
    }
}

// MARK: Wheel

private struct ColorWheel: View {
    let control: LightControl
    @Binding var selection: Set<UInt8>
    let edited: Set<UInt8>

    /// Colors when the drag started, and the dragged pin's starting hue/saturation.
    @State private var dragStart: (colors: [UInt8: LightColor], hue: Double, saturation: Double)?

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                wheel
                    .frame(width: size, height: size)
                    .position(center)
                    .contentShape(Circle())
                    .onTapGesture { location in
                        // Tapping the wheel itself recolors the edited lights to that color.
                        let (hue, saturation) = Self.hueSaturation(at: location, center: center, radius: radius)
                        apply(hue: hue, saturation: saturation, to: edited, keepingOffsetsFrom: nil)
                    }

                ForEach(pinOrder, id: \.self) { channel in
                    if let color = control.colors[channel] {
                        let hsb = color.hsb
                        let point = Self.point(hue: hsb.hue, saturation: hsb.saturation, center: center, radius: radius)
                        Pin(
                            color: color,
                            label: pinLabel(channel),
                            symbol: control.isLamp(channel) ? LightSymbol.name(for: control.channelDescriptions[channel]?.lights.first?.archetype) : nil,
                            isSelected: selection.contains(channel),
                            isEdited: edited.contains(channel)
                        )
                        .position(point)
                        .gesture(dragGesture(channel: channel, center: center, radius: radius))
                        .onTapGesture { select(channel) }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var wheel: some View {
        Circle()
            .fill(AngularGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }, center: .center))
            .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 190)))
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    /// Edited pins drawn last, so they sit on top.
    private var pinOrder: [UInt8] {
        control.area.channels.map(\.id).sorted { a, b in !edited.contains(a) && edited.contains(b) }
    }

    private func pinLabel(_ channel: UInt8) -> String? {
        guard let description = control.channelDescriptions[channel], case .stripSegment(let index, _) = description.kind else { return nil }
        return "\(index + 1)"
    }

    private func select(_ channel: UInt8) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selection.contains(channel) { selection.remove(channel) } else { selection.insert(channel) }
        } else {
            selection = [channel]
        }
    }

    private func dragGesture(channel: UInt8, center: CGPoint, radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    // Dragging a pin outside the selection selects it alone.
                    if !edited.contains(channel) { selection = [channel] }
                    let hsb = (control.colors[channel] ?? .white).hsb
                    dragStart = (control.colors, hsb.hue, hsb.saturation)
                }
                let (hue, saturation) = Self.hueSaturation(at: value.location, center: center, radius: radius)
                let group = edited.contains(channel) ? edited : [channel]
                apply(hue: hue, saturation: saturation, to: group, keepingOffsetsFrom: dragStart)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Recolors `channels`. With a drag start, each light keeps its hue offset from the dragged pin
    /// and its saturation scales with the drag; otherwise all take exactly this hue and saturation.
    private func apply(hue: Double, saturation: Double, to channels: Set<UInt8>, keepingOffsetsFrom start: (colors: [UInt8: LightColor], hue: Double, saturation: Double)?) {
        var updates: [UInt8: LightColor] = [:]
        for channel in channels {
            let original = (start?.colors[channel] ?? control.colors[channel] ?? .white).hsb
            let brightness = original.brightness > 0.01 ? original.brightness : 1
            if let start {
                let newHue = (original.hue + hue - start.hue).truncatingRemainder(dividingBy: 1) + (original.hue + hue - start.hue < 0 ? 1 : 0)
                let ratio = start.saturation > 0.01 ? saturation / start.saturation : 1
                let newSaturation = start.saturation > 0.01 ? min(1, original.saturation * ratio) : saturation
                updates[channel] = LightColor(hue: newHue, saturation: newSaturation, brightness: brightness)
            } else {
                updates[channel] = LightColor(hue: hue, saturation: saturation, brightness: brightness)
            }
        }
        control.setColors(updates)
    }

    /// Angle around the wheel is hue (0 at 3 o'clock, clockwise, matching the gradient); distance from
    /// the center is saturation.
    static func hueSaturation(at location: CGPoint, center: CGPoint, radius: CGFloat) -> (Double, Double) {
        let dx = location.x - center.x, dy = location.y - center.y
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        return (angle / (2 * .pi), min(1, hypot(dx, dy) / radius))
    }

    static func point(hue: Double, saturation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = hue * 2 * .pi
        let distance = saturation * radius
        return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }
}

private struct Pin: View {
    let color: LightColor
    let label: String?
    let symbol: String?
    let isSelected: Bool
    let isEdited: Bool

    var body: some View {
        let size: CGFloat = symbol == nil ? 24 : 32
        ZStack {
            Circle()
                .fill(color.fullBrightness.color)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color.fullBrightness.prefersDarkText ? .black.opacity(0.7) : .white)
            } else if let label {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color.fullBrightness.prefersDarkText ? .black.opacity(0.7) : .white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3.5 : 2))
        .overlay {
            if isSelected {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .opacity(isEdited ? 1 : 0.55)
        .contentShape(Circle())
    }
}

// MARK: Brightness

private struct BrightnessBar: View {
    let control: LightControl
    let edited: Set<UInt8>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { brightness }, set: setBrightness), in: 0...1)
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.secondary)
            Text("\(Int((brightness * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// Average brightness of the edited lights.
    private var brightness: Double {
        let values = edited.compactMap { control.colors[$0]?.hsb.brightness }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func setBrightness(_ value: Double) {
        var updates: [UInt8: LightColor] = [:]
        for channel in edited {
            let hsb = (control.colors[channel] ?? .white).hsb
            updates[channel] = LightColor(hue: hsb.hue, saturation: hsb.saturation, brightness: value)
        }
        control.setColors(updates)
    }
}

// MARK: Lights

private struct LightsPanel: View {
    let control: LightControl
    @Binding var selection: Set<UInt8>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lights").font(.headline)
                Spacer()
                Button(selection.isEmpty ? "All Selected" : "Select All") { selection = [] }
                    .buttonStyle(.link)
                    .disabled(selection.isEmpty)
            }

            ForEach(control.strips, id: \.light) { strip in
                VStack(alignment: .leading, spacing: 6) {
                    Button { selection = Set(strip.channels) } label: {
                        Label(strip.light.name, systemImage: "light.strip.2")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .help("Select the whole strip")
                    HStack(spacing: 3) {
                        ForEach(strip.channels, id: \.self) { channel in
                            RoundedRectangle(cornerRadius: 4)
                                .fill((control.colors[channel] ?? .black).color)
                                .frame(height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(isHighlighted(channel) ? Color.accentColor : .secondary.opacity(0.3), lineWidth: isHighlighted(channel) ? 2.5 : 1)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { select(channel) }
                        }
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
                }
            }

            let lamps = control.lampChannels
            if !lamps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(lamps, id: \.self) { channel in
                        let description = control.channelDescriptions[channel]
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill((control.colors[channel] ?? .black).color)
                                    .shadow(color: (control.colors[channel] ?? .black).color.opacity(0.8), radius: 8)
                                Image(systemName: LightSymbol.name(for: description?.lights.first?.archetype))
                                    .foregroundStyle((control.colors[channel] ?? .black).prefersDarkText ? .black.opacity(0.7) : .white)
                            }
                            .frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(isHighlighted(channel) ? Color.accentColor : .clear, lineWidth: 2.5).padding(-4))
                            Text(description?.name.nilIfEmpty ?? String(localized: "Channel \(channel)"))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { select(channel) }
                    }
                }
            }
        }
    }

    private func isHighlighted(_ channel: UInt8) -> Bool {
        selection.contains(channel)
    }

    private func select(_ channel: UInt8) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selection.contains(channel) { selection.remove(channel) } else { selection.insert(channel) }
        } else {
            selection = selection == [channel] ? [] : [channel]
        }
    }
}

// MARK: Scenes

private struct ScenesPanel: View {
    let control: LightControl

    private static let whites: [(name: String, color: LightColor)] = [
        (String(localized: "Warm", comment: "White light scene"), LightColor(red: 1, green: 0.66, blue: 0.36)),
        (String(localized: "Neutral", comment: "White light scene"), LightColor(red: 1, green: 0.86, blue: 0.7)),
        (String(localized: "Cool", comment: "White light scene"), LightColor(red: 0.82, green: 0.9, blue: 1)),
        (String(localized: "Off", comment: "Light scene that switches the lights off"), .black),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scenes").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(Self.whites, id: \.name) { white in
                    SceneChip(name: white.name, fill: AnyShapeStyle(white.color.color)) {
                        control.setAllColors(white.color)
                    }
                }
                ForEach(MusicPalette.allCases, id: \.self) { palette in
                    SceneChip(
                        name: palette.title,
                        fill: AnyShapeStyle(LinearGradient(colors: palette.colors.map(\.color), startPoint: .leading, endPoint: .trailing))
                    ) {
                        control.setColors(sceneColors(palette))
                    }
                }
            }
        }
    }

    /// The palette spread across each strip as a gradient, with lamps in contrasting colors.
    private func sceneColors(_ palette: MusicPalette) -> [UInt8: LightColor] {
        var colors: [UInt8: LightColor] = [:]
        let count = Double(palette.colors.count)
        for strip in control.strips {
            let last = Double(max(strip.channels.count - 1, 1))
            for (index, channel) in strip.channels.enumerated() {
                colors[channel] = palette.color(at: Double(index) / last * (count - 1))
            }
        }
        for (index, channel) in control.lampChannels.enumerated() {
            colors[channel] = palette.color(at: count / 2 + Double(index))
        }
        return colors
    }
}

private struct SceneChip: View {
    let name: String
    let fill: AnyShapeStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(fill)
                    .frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.35)))
                Text(name)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Color helpers

extension LightColor {
    /// Hue, saturation and brightness, each 0...1.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = (green - blue) / delta
            } else if maximum == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum > 0 ? delta / maximum : 0, maximum)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6
        let sector = Int(h) % 6
        let f = h - floor(h)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    /// The same hue and saturation at full brightness, for showing a dimmed light's color.
    var fullBrightness: LightColor {
        let hsb = hsb
        return LightColor(hue: hsb.hue, saturation: hsb.saturation, brightness: 1)
    }

    /// Whether text on this color reads better dark than white.
    var prefersDarkText: Bool {
        0.299 * red + 0.587 * green + 0.114 * blue > 0.65
    }
}

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
