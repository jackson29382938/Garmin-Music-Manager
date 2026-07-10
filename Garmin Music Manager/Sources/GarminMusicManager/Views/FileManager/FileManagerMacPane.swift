import SwiftUI

/// Right-hand Mac pane for File Manager: Folders or Apple Music.
struct FileManagerMacPane: View {
    @EnvironmentObject private var model: AppModel
    @Binding var macMode: FileManagerMacMode
    @ObservedObject var folderBrowser: LocalFolderBrowserStore
    var onAppleMusicQuickOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch macMode {
            case .folders:
                LocalFolderBrowserView(store: folderBrowser)
            case .appleMusic:
                AppleMusicLibraryBrowser(
                    presentation: .fileManager,
                    showsHeader: false,
                    onCopyToGarmin: { urls in
                        model.uploadFilesToDevice(urls)
                    },
                    onSendToWatch: { trackIDs in
                        let urls = model.musicLibrary.importableURLs(for: trackIDs)
                        guard !urls.isEmpty else { return }
                        Task {
                            await model.addFiles(urls)
                            model.beginSend()
                        }
                    },
                    onAddToTransferQueue: { trackIDs in
                        model.importLibraryTracks(trackIDs)
                    }
                )
            }
        }
        .background(AppTheme.panelBackground(for: .mac).opacity(0.35))
    }

    private var header: some View {
        PanelHeader(
            side: .mac,
            title: "Mac",
            subtitle: macSubtitle,
            systemImage: macMode == .folders ? "folder" : "music.note.list",
            chips: macChips
        ) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $macMode) {
                    ForEach(FileManagerMacMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Button {
                    onAppleMusicQuickOpen()
                } label: {
                    Label("Apple Music", systemImage: "music.note.list")
                }
                .help("Switch to Apple Music library")
                .disabled(macMode == .appleMusic)
            }
        }
    }

    private var macSubtitle: String {
        switch macMode {
        case .folders:
            return folderBrowser.breadcrumbPath
        case .appleMusic:
            return model.musicLibraryStatus.message
        }
    }

    private var macChips: [String] {
        switch macMode {
        case .folders:
            var chips = ["\(folderBrowser.displayedEntries.count) shown"]
            if !folderBrowser.selectedIDs.isEmpty {
                chips.append("\(folderBrowser.selectedIDs.count) selected")
            }
            return chips
        case .appleMusic:
            return []
        }
    }
}
