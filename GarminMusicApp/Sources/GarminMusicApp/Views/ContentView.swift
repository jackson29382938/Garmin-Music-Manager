import SwiftCrossUI
import GarminMusicCore

struct ContentView: View {
    let state: AppState

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                BrandHeader()
                    .padding(12)
                Divider()
                List(AppTab.allCases, selection: state.$selectedTab) { tab in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.rawValue)
                            .font(.system(size: 14))
                        Text(tab.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                }
                Spacer()
            }
            .frame(minWidth: 210)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(state: state)
            }
        }
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            switch state.selectedTab ?? .library {
            case .library:
                LibraryView(state: state)
            case .transfer:
                TransferView(state: state)
            case .onWatch:
                OnWatchView(state: state)
            case .settings:
                SettingsView(state: state)
            }
        }
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("GM")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .padding(10)
                .background(Theme.accent)
                .cornerRadius(10)
            VStack(alignment: .leading, spacing: 1) {
                Text("Garmin Music")
                    .font(.system(size: 15))
                Text("Manager")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct StatusBar: View {
    var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text(state.statusMessage)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Spacer()
            if state.isSending || state.isScanning {
                Text(state.isSending ? "Sending…" : "Scanning…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
