import HueKit
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blask Sync").font(.headline)

            if let credentials = model.credentials {
                PairedView(model: model, credentials: credentials)
            } else if case .waitingForLinkButton(_, let deadline) = model.pairing {
                LinkButtonView(deadline: deadline, onCancel: model.cancelPairing)
            } else {
                bridgeList
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit Blask Sync") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 320)
    }

    private var bridgeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bridges").font(.subheadline.bold())
                Spacer()
                if model.isDiscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Search Again") { Task { await model.discover() } }
                        .buttonStyle(.link)
                }
            }

            if model.bridges.isEmpty && model.isDiscovering {
                Text("Searching your network…").foregroundStyle(.secondary)
            }
            ForEach(model.bridges) { bridge in
                HStack {
                    VStack(alignment: .leading) {
                        Text(bridge.name ?? "Hue Bridge")
                        Text(bridge.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair") { model.pair(with: bridge) }
                }
            }

            HStack {
                TextField("Bridge IP address", text: $model.manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button("Add", action: addManual)
                    .disabled(model.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addManual() {
        Task { await model.addManualBridge() }
    }
}

private struct LinkButtonView: View {
    let deadline: Date
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Press the link button on your Hue Bridge")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(remaining) s remaining").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel", action: onCancel)
        }
    }
}

private struct PairedView: View {
    let model: AppModel
    let credentials: BridgeCredentials

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading) {
                    Text(credentials.name ?? "Hue Bridge")
                    Text("\(credentials.host) · \(credentials.bridgeId)").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                Text("Entertainment areas").font(.subheadline.bold())
                Spacer()
                Button("Refresh") { Task { await model.refreshAreas() } }
                    .buttonStyle(.link)
            }
            if model.areas.isEmpty {
                Text("None yet. Create one in the Hue app under Settings → Entertainment areas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.areas) { area in
                HStack {
                    Text(area.name)
                    Spacer()
                    Text("\(area.configurationType) · \(area.channelCount) ch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Forget Bridge", role: .destructive, action: model.forgetBridge)
        }
    }
}
