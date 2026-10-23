import HueKit
import SwiftUI

/// The Settings window (⌘,): bridge and area in General, screen mapping in Screen, music sync in Music.
struct SettingsView: View {
    let model: AppModel
    @AppStorage("settingsTab") private var selection = Tab.general

    enum Tab: String {
        case general, screen, music
    }

    var body: some View {
        // Explicit tags: without them SwiftUI infers tab identity from the content, and two tabs whose
        // content shares an `.id` showed the same toolbar label.
        TabView(selection: $selection) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ScreenSettings(model: model)
                .tabItem { Label("Screen", systemImage: "display") }
                .tag(Tab.screen)
            MusicSettings(model: model)
                .tabItem { Label("Music", systemImage: "hifispeaker.fill") }
                .tag(Tab.music)
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    let model: AppModel
    @State private var manualHost = ""

    var body: some View {
        Form {
            Section("Hue Bridge") {
                if let credentials = model.credentials {
                    pairedBridge(credentials)
                } else if case .waitingForLinkButton(_, let deadline) = model.pairing {
                    LinkButtonView(deadline: deadline, onCancel: model.cancelPairing)
                } else {
                    bridgeDiscovery
                }
            }

            if model.credentials != nil {
                areaSection
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 380)
    }

    private func pairedBridge(_ credentials: BridgeCredentials) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
            VStack(alignment: .leading) {
                Text(credentials.name ?? "Hue Bridge")
                Text("\(credentials.host) · \(credentials.bridgeId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget…", role: .destructive, action: model.forgetBridge)
        }
    }

    @ViewBuilder
    private var bridgeDiscovery: some View {
        HStack {
            Text(model.isDiscovering ? "Searching your network…" : "Bridges found on your network")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isDiscovering {
                ProgressView().controlSize(.small)
            } else {
                Button("Search Again") { Task { await model.discover() } }
            }
        }
        ForEach(model.bridges) { bridge in
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(bridge.name ?? "Hue Bridge")
                    Text(bridge.host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pair") { model.pair(with: bridge) }
                    .buttonStyle(.borderedProminent)
            }
        }
        HStack {
            TextField("Bridge IP address", text: $manualHost)
                .onSubmit(addManual)
            Button("Add", action: addManual)
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var areaSection: some View {
        Section {
            if model.areas.isEmpty {
                Text("No entertainment areas yet. Create one in the Hue app under Settings → Entertainment areas.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Default area", selection: areaSelection) {
                    ForEach(model.areas) { area in
                        VStack(alignment: .leading) {
                            Text(area.name)
                            Text("\(area.configurationType.capitalized) · \(area.channels.count) channels")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(area.id))
                    }
                }
                .pickerStyle(.radioGroup)
            }
        } header: {
            HStack {
                Text("Entertainment Area")
                Spacer()
                Button("Refresh") { Task { await model.refreshAreas() } }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } footer: {
            Text("Blask Sync drives this area when you start sync from the menu bar.")
        }
    }

    private var areaSelection: Binding<String?> {
        Binding(get: { model.defaultAreaId }, set: { model.defaultAreaId = $0 })
    }

    private func addManual() {
        let host = manualHost
        manualHost = ""
        Task { await model.addBridge(host: host) }
    }
}

private struct LinkButtonView: View {
    let deadline: Date
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Press the link button on your Hue Bridge")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(remaining) s remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("Cancel", action: onCancel)
        }
    }
}

// MARK: Screen

private struct ScreenSettings: View {
    let model: AppModel

    var body: some View {
        Group {
            if let control = model.lightControl {
                ScreenSettingsPane(control: control)
                    .id("screen-\(control.area.id)")
            } else {
                ContentUnavailableView(
                    "No Area Selected",
                    systemImage: "display",
                    description: Text("Pair a bridge and choose an entertainment area in General.")
                )
            }
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}

private struct ScreenSettingsPane: View {
    let control: LightControl

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(control.area.name).font(.title3.bold())
                SyncStatusLabel(control: control)
                Spacer()
                SyncButton(control: control)
            }
            if let error = control.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            ScreenMappingView(control: control)
        }
        .padding()
    }
}
