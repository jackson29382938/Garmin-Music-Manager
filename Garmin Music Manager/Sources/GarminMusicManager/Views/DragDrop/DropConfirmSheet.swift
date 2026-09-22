import SwiftUI

/// Confirms large / destructive / replace drops before executing.
struct DropConfirmSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: PendingDropRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm \(request.operation.displayName)")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                labeled("Items", "\(request.items.itemCount)")
                labeled("Size", ByteCountFormatter.string(fromByteCount: request.items.totalByteCount, countStyle: .file))
                labeled("From", request.sourceLabel)
                labeled("To", request.destinationLabel)
                labeled("Operation", request.operation.displayName)
                labeled("Overwrite", model.syncSettings.overwritePolicy.rawValue)
                if let free = model.deviceBrowser.storageInfo?.availableCapacity {
                    labeled("Watch free", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                }
            }

            if !request.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelPendingDrop()
                }
                .keyboardShortcut(.cancelAction)

                Button(request.operation.displayName) {
                    model.confirmPendingDrop()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
