import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style Mac folder browser used in File Manager.
struct LocalFolderBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: LocalFolderBrowserStore
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = store.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                Divider()
            }
            content
        }
        .background(AppTheme.panelBackground(for: .mac).opacity(isDropTarget ? 1 : 0))
        .overlay {
            ZStack {
                if isDropTarget {
                    Text("Drop to copy from Garmin")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.macTint)
                }
                RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
                    .strokeBorder(isDropTarget ? AppTheme.macTint : Color.clear, lineWidth: 2)
                    .padding(4)
            }
        }
        .onDrop(
            of: [DeviceFileDragPayload.typeIdentifier, UTType.fileURL.identifier],
            isTargeted: canAcceptDrop ? $isDropTarget : .constant(false)
        ) { providers in
            handleDrop(providers)
        }
    }

    private var canAcceptDrop: Bool {
        !model.isManagingDeviceFiles && !store.isRefreshing
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.navigateUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(!store.canNavigateUp)

                Button {
                    store.chooseFolder()
                } label: {
                    Label("Choose…", systemImage: "folder")
                }

                Button {
                    store.jumpToMusicFolder()
                } label: {
                    Label("Music", systemImage: "music.note")
                }
                .help("Jump to ~/Music")

                Spacer(minLength: 8)

                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this folder", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
            }

            Text(store.breadcrumbPath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(AppTheme.panelBackground(for: .mac).opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        let entries = store.displayedEntries
        if entries.isEmpty {
            Text(store.searchText.isEmpty ? "This folder is empty." : "No items match the search.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(entries, selection: $store.selectedIDs) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.systemImage)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            store.open(entry)
                        }
                        .onDrag {
                            dragProvider(for: entry)
                        }
                        .contextMenu {
                            entryContextMenu(for: entry)
                        }
                }
                TableColumn("Size") { entry in
                    Text(entry.isDirectory
                        ? "—"
                        : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .contextMenu { entryContextMenu(for: entry) }
                }
                TableColumn("Kind") { entry in
                    Text(kindLabel(for: entry))
                        .foregroundStyle(.secondary)
                        .contextMenu { entryContextMenu(for: entry) }
                }
            }
            .contextMenu {
                backgroundContextMenu
            }
        }
    }

    private func kindLabel(for entry: LocalFolderEntry) -> String {
        switch entry.kind {
        case .folder: return "Folder"
        case .audio: return "Audio"
        case .playlist: return "Playlist"
        case .other: return "File"
        }
    }

    private func prepareSelection(for entry: LocalFolderEntry) {
        if !store.selectedIDs.contains(entry.id) {
            store.selectedIDs = [entry.id]
        }
    }

    private func dragProvider(for entry: LocalFolderEntry) -> NSItemProvider {
        prepareSelection(for: entry)
        let urls = store.selectedFileURLs
        if urls.isEmpty {
            return entry.isDirectory
                ? (NSItemProvider(contentsOf: entry.url) ?? NSItemProvider())
                : NSItemProvider()
        }
        return MultiFileDragPayload.itemProvider(for: urls)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: LocalFolderEntry) -> some View {
        Button {
            store.open(entry)
        } label: {
            Label(entry.isDirectory ? "Open" : "Reveal in Finder", systemImage: "arrow.forward")
        }

        Button {
            store.revealInFinder(entry)
        } label: {
            Label("Reveal in Finder", systemImage: "eye")
        }

        Divider()

        Button {
            prepareSelection(for: entry)
            copySelectedToGarmin()
        } label: {
            Label("Copy to Garmin", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.deviceBrowser.isConfigured || model.isManagingDeviceFiles || store.selectedAudioURLs.isEmpty)

        Button {
            prepareSelection(for: entry)
            sendSelectedToWatch()
        } label: {
            Label("Send to Watch", systemImage: "arrow.down.circle")
        }
        .disabled(!model.destinationIsReady || model.isSyncing || store.selectedAudioURLs.isEmpty)

        Divider()

        Button("Select All") {
            store.selectAllDisplayed()
        }
        .disabled(store.displayedEntries.isEmpty)

        Button("Deselect") {
            store.deselectAll()
        }
        .disabled(store.selectedIDs.isEmpty)

        Button {
            store.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
        Button {
            store.chooseFolder()
        } label: {
            Label("Choose Folder…", systemImage: "folder")
        }
        Button {
            store.jumpToMusicFolder()
        } label: {
            Label("Go to Music", systemImage: "music.note")
        }
        Button {
            store.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }

        let garminSelection = model.deviceBrowser.selectedFiles.filter { $0.type != .folder }
        if !garminSelection.isEmpty {
            Divider()
            Button {
                model.downloadSelectedDeviceFiles(to: store.currentFolder)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.refresh()
                }
            } label: {
                Label("Copy Selected Garmin Files Here", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isManagingDeviceFiles || !model.deviceBrowser.isConfigured)
        }

        Divider()
        Button("Select All") {
            store.selectAllDisplayed()
        }
        .disabled(store.displayedEntries.isEmpty)
        Button("Deselect") {
            store.deselectAll()
        }
        .disabled(store.selectedIDs.isEmpty)
    }

    private func copySelectedToGarmin() {
        let urls = store.selectedAudioURLs
        guard !urls.isEmpty else { return }
        model.uploadFilesToDevice(urls)
    }

    private func sendSelectedToWatch() {
        let urls = store.selectedAudioURLs
        guard !urls.isEmpty else { return }
        Task {
            await model.addFiles(urls)
            model.beginSend()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let hasDevice = providers.contains {
            $0.hasItemConformingToTypeIdentifier(DeviceFileDragPayload.typeIdentifier)
        }
        if hasDevice {
            DeviceFileDragPayload.loadIDs(from: providers) { ids in
                guard !ids.isEmpty else { return }
                model.downloadDeviceFiles(withIDs: ids, to: store.currentFolder)
                // Refresh after a short delay so the download task can finish writing.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.refresh()
                }
            }
            return true
        }

        MultiFileDragPayload.loadURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            copyLocalFiles(urls, into: store.currentFolder)
            store.refresh()
        }
        return true
    }

    private func copyLocalFiles(_ urls: [URL], into folder: URL) {
        for url in urls {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                // Best-effort local copy; device ops already surface notices.
            }
        }
    }
}
