import AppKit
import SwiftUI

/// The About tab: app icon, name and version, and who made it.
struct AboutSettings: View {
    let updater: SoftwareUpdater

    private static let authorAvatar = Bundle.main.url(forResource: "Author", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(AppVariant.name).font(.title2.bold())
                Text("Version \(updater.version)")
                    .foregroundStyle(.secondary)
            }

            Divider().frame(width: 200).padding(.vertical, 8)

            HStack(spacing: 10) {
                if let avatar = Self.authorAvatar {
                    Image(nsImage: avatar)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made by \("Miron Pawlik")", comment: "About tab credit; the argument is the author's name")
                    Link(destination: URL(string: "https://miron.asia")!) { Text(verbatim: "miron.asia") }
                }
            }
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Text(verbatim: copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 520)
    }
}
