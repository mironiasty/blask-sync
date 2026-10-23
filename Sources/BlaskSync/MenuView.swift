import HueKit
import SwiftUI

/// The menu bar panel: start and stop sync, open manual control. Setup lives in Settings.
struct MenuView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blask Sync").font(.headline)

            if model.credentials == nil {
                Text("Not connected to a Hue Bridge.")
                    .foregroundStyle(.secondary)
                Button(action: showSettings) {
                    Label("Pair Bridge…", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if let control = model.lightControl {
                syncControls(control)
            } else if model.isLoadingAreas {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to your Hue Bridge…")
                        .foregroundStyle(.secondary)
                }
            } else if model.areas.isEmpty {
                Text("No entertainment areas found. Create one in the Hue app under Settings → Entertainment areas.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose an entertainment area in Settings.")
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit", action: model.quit)
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            // Safety net: if loading failed earlier, opening the menu tries again.
            if model.credentials != nil, model.areas.isEmpty {
                Task { await model.refreshAreas() }
            }
        }
    }

    @ViewBuilder
    private func syncControls(_ control: LightControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(control.area.name)
            SyncStatusLabel(control: control)
                .font(.callout)
        }

        Picker("Sync with", selection: Binding(get: { control.syncSource }, set: { control.syncSource = $0 })) {
            Label("Screen", systemImage: "display").tag(LightControl.SyncSource.screen)
            Label("Music", systemImage: "hifispeaker.fill").tag(LightControl.SyncSource.music)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        SyncButton(control: control, large: true)

        Button {
            openWindow(id: ManualControlView.windowId)
            NSApp.activate()
        } label: {
            Label("Manual Control…", systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)

        if control.syncSource == .screen {
            CaptureStatusBanner(control: control, compact: true)
        } else if let error = control.musicError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let error = control.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
