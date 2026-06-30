import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                HeaderView()
                Divider()
                TrackTableView()
                Divider()
                DeviceContentsView()
                Divider()
                TransferPanelView()
            }
            .toolbar {
                PrimaryActionsToolbar(model: model)
            }
        }
        .sheet(isPresented: $model.showSyncPreview) {
            SyncPreviewSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showAppleMusicBrowser) {
            AppleMusicBrowserView()
                .environmentObject(model)
        }
        .alert("Delete selected files?", isPresented: $model.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.deleteSelectedDeviceFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected audio files from the Garmin or selected destination folder.")
        }
    }
}
