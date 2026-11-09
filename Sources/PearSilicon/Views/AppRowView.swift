import SwiftUI

struct AppRowView: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(app.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if app.isLegacy32Bit {
                        Text("32-bit")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL = app.iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.secondary)
                )
        }
    }
}
