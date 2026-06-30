import SwiftUI

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Playlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Playlist name", text: $model.playlistName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)
                    .onChange(of: model.playlistName) { _, _ in
                        model.updateDuplicateFlags()
                    }
            }
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter tracks", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, idealWidth: 180, maxWidth: 220)
            }

            Spacer(minLength: 0)

            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Primary actions, placed in the window toolbar so they collapse into an
/// overflow menu when the window is squished to a narrow width.
struct PrimaryActionsToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.chooseMusicFiles()
            } label: {
                Label("Add Files", systemImage: "plus")
            }

            Button {
                model.chooseMusicFolder()
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }

            Button {
                model.openAppleMusicBrowser()
            } label: {
                Label("Apple Music", systemImage: "music.note.list")
            }

            Button {
                model.selectAllReady()
            } label: {
                Label("Select Ready", systemImage: "checkmark.circle")
            }
            .disabled(model.tracks.isEmpty)

            Button(role: .destructive) {
                model.clearTracks()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.tracks.isEmpty)
        }
    }
}
