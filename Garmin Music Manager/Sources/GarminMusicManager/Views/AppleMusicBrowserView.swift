import SwiftUI

/// Sheet wrapper around `AppleMusicLibraryBrowser` for Transfer → Apple Music.
struct AppleMusicBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppleMusicLibraryBrowser(
            presentation: .sheet,
            showsHeader: true,
            onDismiss: {
                dismiss()
            }
        )
        .frame(minWidth: 620, idealWidth: 780, minHeight: 440, idealHeight: 580)
        .environmentObject(model)
    }
}
