import SwiftUI

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search Mac library", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 280, maxWidth: 360)

            if !model.searchText.isEmpty {
                Button("Clear") {
                    model.searchText = ""
                }
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct PrimaryActionsToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    model.chooseMusicFiles()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    model.chooseMusicFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button {
                    model.openAppleMusicBrowser()
                } label: {
                    Label("Apple Music", systemImage: "music.note.list")
                }
            } label: {
                Label("Add Music", systemImage: "plus")
            }
            .help("Add music files, folders, or Apple Music tracks")

            Button {
                model.selectAllReady()
            } label: {
                Label("Select Ready", systemImage: "checkmark.circle")
            }
            .labelStyle(.iconOnly)
            .disabled(model.tracks.isEmpty)
            .keyboardShortcut("a", modifiers: .command)
            .help("Select all compatible tracks")

            Button(role: .destructive) {
                model.clearTracks()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(model.tracks.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Clear the Mac Library queue")
        }
    }
}
